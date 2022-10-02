"""
This part of the workflow starts from files

  - builds/{build_name}/sequences.fasta
  - builds/{build_name}/metadata.tsv

and produces files

  - auspice/ncov_{build_name}.json
  - auspice/ncov_{build_name}-tip-frequencies.json
  - auspice/ncov_{build_name}-root-sequence.json

"""


localrules:
    add_branch_labels,
    colors,
    internal_pango,
    overwrite_recombinant_clades,
    add_recombinants_to_tree,
    remove_recombinants_from_alignment,
    identify_recombinants,


build_dir = config.get("build_dir", "builds")
auspice_dir = config.get("auspice_dir", "auspice")
auspice_prefix = config.get("auspice_prefix", "ncov")


rule align:
    message:
        """
        Aligning sequences to {input.reference}
            - gaps relative to reference are considered real
        """
    input:
        sequences=build_dir + "/{build_name}/sequences.fasta",
        genemap=config["files"]["annotation"],
        reference=config["files"]["alignment_reference"],
    output:
        alignment=build_dir + "/{build_name}/aligned.fasta",
        translations=expand(
            build_dir + "/{{build_name}}/translations/aligned.gene.{gene}.fasta",
            gene=config.get("genes", ["S"]),
        ),
    params:
        outdir=lambda w: build_dir
        + f"/{w.build_name}/"
        + "translations/aligned.gene.{gene}.fasta",
        genes=",".join(config.get("genes", ["S"])),
        basename="aligned",
    log:
        "logs/align_{build_name}.txt",
    benchmark:
        "benchmarks/align_{build_name}.txt"
    threads: 4
    resources:
        mem_mb=3000,
    shell:
        """
        nextalign run \
            --jobs={threads} \
            --input-ref {input.reference} \
            --input-gene-map {input.genemap} \
            --genes {params.genes} \
            {input.sequences} \
            --output-translations {params.outdir} \
            --output-fasta {output.alignment} \
            > {log} 2>&1
        """


rule mask:
    message:
        """
        Mask bases in alignment {input.alignment}
          - masking {params.mask_arguments}
        """
    input:
        alignment=rules.align.output.alignment,
    output:
        alignment=build_dir + "/{build_name}/masked.fasta",
    log:
        "logs/mask_{build_name}.txt",
    benchmark:
        "benchmarks/mask_{build_name}.txt"
    params:
        mask_arguments=lambda w: config.get("mask", ""),
    shell:
        """
        python3 scripts/mask-alignment.py \
            --alignment {input.alignment} \
            {params.mask_arguments} \
            --output {output.alignment} 2>&1 | tee {log}
        """


rule identify_recombinants:
    input:
        strains=rules.exclude_outliers.output.sampled_strains,
    output:
        recombinants=build_dir + "/{build_name}/recombinants.txt",
    shell:
        """
        grep '^X' {input.strains} > {output.recombinants}
        """


rule remove_recombinants_from_alignment:
    input:
        alignment=rules.mask.output.alignment,
        recombinants=build_dir + "/{build_name}/recombinants.txt",
    output:
        alignment=build_dir + "/{build_name}/masked_without_recombinants.fasta",
    log:
        "logs/remove_recombinants_{build_name}.txt",
    benchmark:
        "benchmarks/remove_recombinants_{build_name}.txt"
    shell:
        """
        seqkit grep -v -f {input.recombinants} {input.alignment} > {output.alignment}
        2>&1 | tee {log}
        """


rule tree:
    message:
        "Building tree"
    input:
        alignment=rules.remove_recombinants_from_alignment.output.alignment,
        constraint_tree=config["files"]["constraint_tree"],
        exclude_sites=config["files"]["exclude_sites"],
    output:
        tree=build_dir + "/{build_name}/tree_raw.nwk",
    params:
        args=lambda w: config["tree"].get("tree-builder-args", "")
        if "tree" in config
        else "",
    log:
        "logs/tree_{build_name}.txt",
    benchmark:
        "benchmarks/tree_{build_name}.txt"
    threads: 8
    resources:
        # Multiple sequence alignments can use up to 40 times their disk size in
        # memory, especially for larger alignments.
        # Note that Snakemake >5.10.0 supports input.size_mb to avoid converting from bytes to MB.
        mem_mb=lambda wildcards, input: 40 * int(input.size / 1024 / 1024),
    shell:
        """
        augur tree \
            --alignment {input.alignment} \
            --exclude-sites {input.exclude_sites} \
            --tree-builder-args {params.args} \
            --output {output.tree} \
            --nthreads {threads} 2>&1 | tee {log}
        """


rule add_recombinants_to_tree:
    message:
        "Adding recombinant singlets to root of raw tree"
    input:
        tree=rules.tree.output.tree,
        recombinants=build_dir + "/{build_name}/recombinants.txt",
    output:
        tree=build_dir + "/{build_name}/tree_with_recombinants.nwk",
    log:
        "logs/add_recombinants_{build_name}.txt",
    benchmark:
        "benchmarks/add_recombinants_{build_name}.txt"
    params:
        root=config["refine"]["root"],
    shell:
        """
        python scripts/add_recombinants.py \
            --tree {input.tree} \
            --recombinants {input.recombinants} \
            --root {params.root} \
            --output {output.tree} 2>&1 | tee {log}
        """


rule refine:
    message:
        """
        Refining tree
        """
    input:
        tree=rules.add_recombinants_to_tree.output.tree,
        alignment=rules.align.output.alignment,
        metadata="builds/{build_name}/metadata.tsv",
    output:
        tree=build_dir + "/{build_name}/tree.nwk",
        node_data=build_dir + "/{build_name}/branch_lengths.json",
    log:
        "logs/refine_{build_name}.txt",
    benchmark:
        "benchmarks/refine_{build_name}.txt"
    threads: 1
    resources:
        # Multiple sequence alignments can use up to 15 times their disk size in
        # memory.
        # Note that Snakemake >5.10.0 supports input.size_mb to avoid converting from bytes to MB.
        mem_mb=lambda wildcards, input: 15 * int(input.size / 1024 / 1024),
    params:
        root=config["refine"]["root"],
        divergence_unit=config["refine"].get("divergence_unit", "mutations"),
    shell:
        """
        augur refine \
            --tree {input.tree} \
            --alignment {input.alignment} \
            --metadata {input.metadata} \
            --output-tree {output.tree} \
            --output-node-data {output.node_data} \
            --keep-root \
            --divergence-unit {params.divergence_unit} | tee {log}
        """


rule ancestral:
    message:
        """
        Reconstructing ancestral sequences and mutations
          - inferring ambiguous mutations
        """
    input:
        tree=rules.refine.output.tree,
        alignment=rules.align.output.alignment,
    output:
        node_data=build_dir + "/{build_name}/nt_muts.json",
    log:
        "logs/ancestral_{build_name}.txt",
    benchmark:
        "benchmarks/ancestral_{build_name}.txt"
    params:
        inference="joint",
    resources:
        # Multiple sequence alignments can use up to 15 times their disk size in
        # memory.
        # Note that Snakemake >5.10.0 supports input.size_mb to avoid converting from bytes to MB.
        mem_mb=lambda wildcards, input: 15 * int(input.size / 1024 / 1024),
    shell:
        """
        augur ancestral \
            --tree {input.tree} \
            --alignment {input.alignment} \
            --output-node-data {output.node_data} \
            --inference {params.inference} \
            --infer-ambiguous 2>&1 | tee {log}
        """


rule translate:
    message:
        "Translating amino acid sequences"
    input:
        tree=rules.refine.output.tree,
        node_data=rules.ancestral.output.node_data,
        reference=config["files"]["reference"],
    output:
        node_data=build_dir + "/{build_name}/aa_muts.json",
    log:
        "logs/translate_{build_name}.txt",
    benchmark:
        "benchmarks/translate_{build_name}.txt"
    resources:
        # Memory use scales primarily with size of the node data.
        mem_mb=lambda wildcards, input: 3 * int(input.node_data.size / 1024 / 1024),
    shell:
        """
        augur translate \
            --tree {input.tree} \
            --ancestral-sequences {input.node_data} \
            --reference-sequence {input.reference} \
            --output-node-data {output.node_data} 2>&1 | tee {log}
        """


rule aa_muts_explicit:
    message:
        "Translating amino acid sequences"
    input:
        tree=rules.refine.output.tree,
        translations=lambda w: rules.align.output.translations,
    output:
        node_data=build_dir + "/{build_name}/aa_muts_explicit.json",
        translations=expand(
            build_dir
            + "/{{build_name}}/translations/aligned.gene.{gene}_withInternalNodes.fasta",
            gene=config.get("genes", ["S"]),
        ),
    params:
        genes=config.get("genes", "S"),
    log:
        "logs/aamuts_{build_name}.txt",
    benchmark:
        "benchmarks/aamuts_{build_name}.txt"
    resources:
        # Multiple sequence alignments can use up to 15 times their disk size in
        # memory.
        # Note that Snakemake >5.10.0 supports input.size_mb to avoid converting from bytes to MB.
        mem_mb=lambda wildcards, input: 15 * int(input.size / 1024 / 1024),
    shell:
        """
        python3 scripts/explicit_translation.py \
            --tree {input.tree} \
            --translations {input.translations:q} \
            --genes {params.genes} \
            --output {output.node_data} 2>&1 | tee {log}
        """


rule clades:
    message:
        "Adding internal clade labels"
    input:
        tree=rules.refine.output.tree,
        aa_muts=rules.translate.output.node_data,
        nuc_muts=rules.ancestral.output.node_data,
        clades=config["files"]["clades"],
    output:
        node_data=build_dir + "/{build_name}/clades_raw.json",
    log:
        "logs/clades_{build_name}.txt",
    benchmark:
        "benchmarks/clades_{build_name}.txt"
    resources:
        # Memory use scales primarily with size of the node data.
        mem_mb=lambda wildcards, input: 3 * int(input.size / 1024 / 1024),
    shell:
        """
        augur clades --tree {input.tree} \
            --mutations {input.nuc_muts} {input.aa_muts} \
            --clades {input.clades} \
            --output-node-data {output.node_data} 2>&1 | tee {log}
        """


rule overwrite_recombinant_clades:
    input:
        clades_json=rules.clades.output.node_data,
    output:
        node_data=build_dir + "/{build_name}/clades.json",
    log:
        "logs/overwrite_recombinant_clades_{build_name}.txt",
    shell:
        """
        python scripts/overwrite_recombinant_clades.py \
            --clades {input.clades_json} \
            --output {output.node_data} \
        2>&1 | tee {log}
        """


rule internal_pango:
    input:
        tree=rules.refine.output.tree,
        alias=rules.download_pango_alias.output,
        synthetic=rules.synthetic_pick.output,
        designations=rules.pango_strain_rename.output.pango_designations,
    output:
        node_data=build_dir + "/{build_name}/internal_pango.json",
    log:
        "logs/internal_pango_{build_name}.txt",
    shell:
        """
        python scripts/internal_pango.py \
            --tree {input.tree} \
            --synthetic {input.synthetic} \
            --alias {input.alias} \
            --designations {input.designations} \
            --output {output.node_data} \
            --field-name Nextclade_pango 2>&1 | tee {log}
        """


rule colors:
    message:
        "Constructing colors file"
    input:
        ordering=config["files"]["ordering"],
        color_schemes=config["files"]["color_schemes"],
        metadata="builds/{build_name}/metadata.tsv",
    output:
        colors=build_dir + "/{build_name}/colors.tsv",
    log:
        "logs/colors_{build_name}.txt",
    benchmark:
        "benchmarks/colors_{build_name}.txt"
    resources:
        # Memory use scales primarily with the size of the metadata file.
        # Compared to other rules, this rule loads metadata as a pandas
        # DataFrame instead of a dictionary, so it uses much less memory.
        mem_mb=lambda wildcards, input: 5 * int(input.metadata.size / 1024 / 1024),
    shell:
        """
        python3 scripts/assign-colors.py \
            --ordering {input.ordering} \
            --color-schemes {input.color_schemes} \
            --output {output.colors} \
            --metadata {input.metadata} 2>&1 | tee {log}
        """


def _get_node_data_by_wildcards(wildcards):
    """Return a list of node data files to include for a given build's wildcards."""
    # Define inputs shared by all builds.
    wildcards_dict = dict(wildcards)
    inputs = [
        rules.refine.output.node_data,
        rules.ancestral.output.node_data,
        rules.translate.output.node_data,
        rules.overwrite_recombinant_clades.output.node_data,
        rules.aa_muts_explicit.output.node_data,
        rules.internal_pango.output.node_data,
    ]
    if "distances" in config:
        inputs.append(rules.distances.output.node_data)

    # Convert input files from wildcard strings to real file names.
    inputs = [input_file.format(**wildcards_dict) for input_file in inputs]
    return inputs


rule export:
    message:
        "Exporting data files for auspice"
    input:
        tree=rules.refine.output.tree,
        metadata="builds/{build_name}/metadata.tsv",
        node_data=_get_node_data_by_wildcards,
        auspice_config=lambda w: config["builds"][w.build_name]["auspice_config"]
        if "auspice_config" in config["builds"][w.build_name]
        else config["files"]["auspice_config"],
        description=lambda w: config["builds"][w.build_name]["description"]
        if "description" in config["builds"][w.build_name]
        else config["files"]["description"],
        colors=lambda w: rules.colors.output.colors.format(**w),
    output:
        auspice_json="auspice/{build_name}/auspice_raw.json",
        root_json="auspice/{build_name}/auspice_raw_root-sequence.json",
    log:
        "logs/export_{build_name}.txt",
    benchmark:
        "benchmarks/export_{build_name}.txt"
    params:
        title=lambda w: config["builds"][w.build_name].get(
            "title", "SARS-CoV-2 phylogeny"
        ),
    resources:
        # Memory use scales primarily with the size of the metadata file.
        mem_mb=lambda wildcards, input: 15 * int(input.metadata.size / 1024 / 1024),
    shell:
        """
        augur export v2 \
            --tree {input.tree} \
            --metadata {input.metadata} \
            --node-data {input.node_data} \
            --colors {input.colors} \
            --auspice-config {input.auspice_config} \
            --title {params.title:q} \
            --description {input.description} \
            --include-root-sequence \
            --output {output.auspice_json} 2>&1 | tee {log};
        """


rule add_branch_labels:
    message:
        "Adding custom branch labels to the Auspice JSON"
    input:
        auspice_json=rules.export.output.auspice_json,
        mutations=rules.aa_muts_explicit.output.node_data,
    output:
        auspice_json="auspice/{build_name}/auspice.json",
    log:
        "logs/add_branch_labels_{build_name}.txt",
    shell:
        """
        python3 scripts/add_branch_labels.py \
            --input {input.auspice_json} \
            --mutations {input.mutations} \
            --output {output.auspice_json}
        """


rule remove_recombinants_from_auspice:
    input:
        auspice_json=rules.add_branch_labels.output.auspice_json,
    output:
        auspice_json="auspice/{build_name}/auspice_without_recombinants.json",
    log:
        "logs/remove_recombinants_from_auspice_{build_name}.txt",
    shell:
        """
        python3 scripts/remove_recombinants_from_auspice.py \
            --input {input.auspice_json} \
            --output {output.auspice_json}
        """


rule produce_trees:
    input:
        "auspice/nextclade/auspice.json",
        "auspice/nextclade/auspice_without_recombinants.json",
