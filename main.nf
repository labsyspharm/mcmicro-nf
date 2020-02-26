#!/usr/bin/env nextflow

// Variable naming conventions
// path_* - directories
// fn_*   - filenames
// cls_*  - closures (functions)
// tp_*   - tuples

// Expecting params
// .in - location of the data

// Default parameters
params.sample_name = file(params.in).name
params.tools       = "$HOME/mcmicro"
params.TMA         = false
params.skip_ashlar = false

// Define tools
// NOTE: Some of these values are overwritten by nextflow.config
params.tool_core    = "${params.tools}/Coreograph"
params.tool_unmicst = "${params.tools}/UnMicst"
params.tool_segment = "${params.tools}/S3segmenter"

// Define all subdirectories
path_raw  = "${params.in}/raw_images"
path_ilp  = "${params.in}/illumination_profiles"
path_rg   = "${params.in}/registration"
path_dr   = "${params.in}/dearray"
path_prob = "${params.in}/prob_maps"
path_seg  = "${params.in}/segmentation"

// Create intermediate directories
file(path_rg).mkdir()
file(path_dr).mkdir()
file(path_prob).mkdir()
file(path_seg).mkdir()

// Define closures / functions
//   Filename from full path: {/path/to/file.ext -> file.ext}
cls_base = { fn -> file(fn).name }

//   Channel from path p if cond is true, empty channel if false
cls_ch = { cond, p -> cond ? Channel.fromPath(p) : Channel.empty() }

//   Extract image ID from filename
cls_tok = { x, sep -> x.toString().tokenize(sep).get(0) }
cls_id  = { fn -> cls_tok(cls_tok(fn,'.'),'_') }
cls_fid = { file -> tuple(cls_id(file.getBaseName()), file) }

// If we're running ASHLAR, find raw images and illumination profiles
raw = cls_ch( !params.skip_ashlar, "${path_raw}/*.ome.tiff" ).toSortedList()
dfp = cls_ch( !params.skip_ashlar, "${path_ilp}/*-dfp.tif" ).toSortedList()
ffp = cls_ch( !params.skip_ashlar, "${path_ilp}/*-ffp.tif" ).toSortedList()

// If we're not running ASHLAR, find the pre-stitched image
fn_stitched = "${params.sample_name}.ome.tif"
prestitched = cls_ch( params.skip_ashlar, "${path_rg}/*.ome.tif" )

// Stitching and registration
process ashlar {
    publishDir path_rg, mode: 'copy'
    
    input:
    file raw
    file ffp
    file dfp

    output:
    file "${fn_stitched}" into stitched

    when:
    !params.skip_ashlar

    """
    ashlar $raw -m 30 --pyramid --ffp $ffp --dfp $dfp -f ${fn_stitched}
    """
}

// Mix mutually-exclusive channels (dependent on params.skip_ashlar)
// Forward the result to channel tma or tissue based on params.TMA flag
stitched
    .mix( prestitched )
    .branch {
      tissue: !params.TMA
      tma: params.TMA
    }
    .set {img}

// De-arraying (if TMA)
process dearray {
    publishDir path_dr,  mode: 'copy'

    // Mix mutually-exclusive channels (dependent on params.skip_ashlar)
    input:
    file s from img.tma
    
    output:
    file "**{[A-Z],[A-Z][A-Z]}{[0-9],[0-9][0-9]}.tif" into cores
    file "**_mask.tif" into masks

    when:
    params.TMA

    """
    matlab -nodesktop -nosplash -r \
    "addpath(genpath('${params.tool_core}')); \
     tmaDearray('./$s','outputPath','.'); exit"
    """
}

// Collapse the earlier branching between full-tissue and TMA into
//   a single img channel for all downstream processing
img.tissue.mix(cores).set{ imgs }
    
// Duplicate images for 1) UNet and 2) S3segmenter
imgs.into{ imgs1; imgs2 }

// UNet classification
process unmicst {
    publishDir path_prob, mode: 'copy'

    input:
    file core from imgs1.flatten()

    output:
    file '*Nuclei*.tif' into probs_n
    file '*Contours*.tif' into probs_c

    """
    python ${params.tool_unmicst}/UnMicst.py $core --outputPath .
    """
}

// Extract core ID from each filename
imgs2.flatten().map(cls_fid).into{ tp_cores; tp_cores2 }
probs_n.flatten().map(cls_fid).set{ tp_probs_n }
probs_c.flatten().map(cls_fid).set{ tp_probs_c }

// If we're working with TMA, the masks are produced by dearray
// If we're working with single tissue, create dummy placeholders
if( params.TMA ) 
    tp_masks = masks.flatten().map(cls_fid)
else
    tp_masks = tp_cores2.map{ id, fn -> tuple(id, file('NO_FILE')) }

// Use core IDs to match up file tuples for segmentation
tp_s3seg = tp_cores.join(tp_masks).join(tp_probs_n).join(tp_probs_c)

// Segmentation
process s3seg {
    publishDir path_seg, mode: 'copy'

    input:
    set id, file(core), file(mask), file(pmn), file(pmc) from tp_s3seg

    output:
    file '**' into segmented

    script:
    def crop = params.TMA ? 'dearray' : 'noCrop'
    """
    python ${params.tool_segment}/S3segmenter.py --crop $crop \
       --imagePath $core \
       --maskPath $mask \
       --nucleiClassProbPath $pmn \
       --contoursClassProbPath $pmc \
       --outputPath .
    """
}
