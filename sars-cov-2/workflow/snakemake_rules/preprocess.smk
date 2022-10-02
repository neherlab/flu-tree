"""
Download and prepare workflow input data
"""


localrules:
    join_meta_nextclade,
    download_clade_emergence_dates,
    download_pango_alias,
    download_sequences,
    download_metadata,
    download_exclude,
    download_clades,
    preprocess,
    download_color_ordering,
    download_designations,


rule preprocess:
    input:
        sequences="data/sequences.fasta.zst",
        metadata="data/metadata.tsv.zst",
        problematic_exclude="pre-processed/problematic_exclude.txt",
        synthetic="pre-processed/synthetic.fasta",
    params:
        slack_hook=config.get("slackHook", "google.com"),
    shell:
        """
        curl -X POST -H 'Content-type: application/json' \
        --data '{{"text":"Preprocessing done"}}' \
        {params.slack_hook}
        """


rule download_sequences:
    message:
        "Downloading sequences from {params.address} -> {output[0]}"
    params:
        address="s3://nextstrain-ncov-private/sequences.fasta.zst",
    output:
        "data/sequences.fasta.zst",
    shell:
        "aws s3 cp {params.address} {output}"


rule download_metadata:
    message:
        "Downloading metadata from {params.address} -> {output}"
    params:
        address="s3://nextstrain-ncov-private/metadata.tsv.zst",
    output:
        metadata="data/metadata_raw.tsv.zst",
    shell:
        "aws s3 cp {params.address} {output:q}"


rule fix_metadata:
    input:
        "data/metadata_raw.tsv.zst",
    output:
        "data/metadata_raw2.tsv.zst",
    shell:
        """
        zstdcat {input} | \
        awk  -F'\t' 'BEGIN {{OFS = FS}} {{if ($NF=="?") $NF="-inf"; print}}' {input} | \
        zstd -o {output}
        """


rule download_clades:
    message:
        "Downloading clade definitions from {params.source} -> {output}"
    output:
        "builds/clades.tsv",
    params:
        source="https://raw.githubusercontent.com/nextstrain/ncov/master/defaults/clades.tsv",
    shell:
        "curl {params.source} -o {output}"


rule download_color_ordering:
    message:
        "Downloading clade definitions from {params.source} -> {output}"
    output:
        "builds/color_ordering.tsv",
    params:
        source="https://raw.githubusercontent.com/nextstrain/ncov/master/defaults/color_ordering.tsv",
    shell:
        "curl {params.source} -o {output}"


rule download_lat_longs:
    message:
        "Downloading clade definitions from {params.source} -> {output}"
    output:
        "builds/lat_longs.tsv",
    params:
        source="https://raw.githubusercontent.com/nextstrain/ncov/master/defaults/lat_longs.tsv",
    shell:
        "curl {params.source} -o {output}"


rule download_designations:
    output:
        "pre-processed/designations.csv",
    params:
        source="https://raw.githubusercontent.com/cov-lineages/pango-designation/master/lineages.csv",
    shell:
        "curl {params.source} -o {output}"


rule download_pango_alias:
    output:
        "pre-processed/alias.json",
    params:
        source="https://raw.githubusercontent.com/cov-lineages/pango-designation/master/pango_designation/alias_key.json",
    shell:
        "curl {params.source} -o {output}"


rule download_clade_emergence_dates:
    output:
        "pre-processed/clade_emergence_dates.tsv",
    params:
        source="https://raw.githubusercontent.com/nextstrain/ncov/master/defaults/clade_emergence_dates.tsv",
    shell:
        "curl {params.source} -o {output}"


rule nextclade_strainnames:
    message:
        "Extract strain names using tsv-select"
    input:
        "data/metadata_raw2.tsv.zst",
    output:
        "pre-processed/metadata_strainnames.tsv.zst",
    shell:
        """
        zstdcat {input} | \
        tsv-select -H -f strain | \
        zstd -o {output}
        """


rule pango_strain_rename:
    message:
        "Convert pango strain names to nextclade strain names"
    input:
        metadata_strainnames="pre-processed/metadata_strainnames.tsv.zst",
        pango="pre-processed/designations.csv",
    output:
        pango_designations="pre-processed/pango_designations_nextstrain_names.csv",
        pango_designated_strains="pre-processed/pango_designated_strains_nextstrain_names.txt",
    shell:
        """
        python3 scripts/pango_strain_rename.py \
        --metadata-strainnames {input.metadata_strainnames} \
        --pango-in {input.pango} \
        --pango-designations {output.pango_designations} \
        --pango-designated-strains {output.pango_designated_strains} \
        2>&1
        """


rule fix_pango_lineages:
    message:
        "Add new column to open_pango_metadata_raw.tsv by joining designations.csv on field strain name"
    input:
        metadata="data/metadata_raw2.tsv.zst",
        pango_designations="pre-processed/pango_designations_nextstrain_names.csv",
    output:
        metadata="data/metadata.tsv.zst",
    shell:
        """
        zstdcat {input.metadata} | \
        python3 scripts/fix_open_pango_lineages.py \
        --metadata /dev/stdin \
        --designations {input.pango_designations} \
        --output data/metadata.tsv \
        2>&1
        zstd data/metadata.tsv
        """


rule get_designated_sequences:
    input:
        sequences="data/sequences.fasta.zst",
        pango="pre-processed/pango_designated_strains_nextstrain_names.txt",
    output:
        sequences="pre-processed/open_pango.fasta.zst",
    log:
        "logs/get_designated_sequences.txt",
    benchmark:
        "benchmarks/get_designated_sequences.txt"
    threads: 7
    shell:
        """
        zstdcat -T2 {input.sequences} | \
        seqkit grep -f {input.pango} 2>{log} | \
        zstd -c -10 -T4  >{output.sequences}
        """


rule get_designated_strains:
    input:
        sequences=rules.get_designated_sequences.output.sequences,
    output:
        strains="pre-processed/open_pango_strains.txt",
    log:
        "logs/get_designated_strains.txt",
    benchmark:
        "benchmarks/get_designated_strains.txt"
    threads: 3
    shell:
        """
        zstdcat -T2 {input.sequences} | \
        seqkit seq -in -o {output.strains} 2>{log}
        """


rule get_designated_metadata:
    input:
        strains="pre-processed/open_pango_strains.txt",
        metadata="data/metadata.tsv.zst",
    output:
        metadata="pre-processed/open_pango_metadata.tsv.zst",
    log:
        "logs/get_designated_metadata.txt",
    benchmark:
        "benchmarks/get_designated_metadata.txt"
    shell:
        """
        zstdcat {input.metadata} | \
        tsv-join -H --filter-file {input.strains} --key-fields 1 {input.metadata} 2>&1 | \
        zstd -o {output.metadata}
        """


rule strains:
    input:
        "data/metadata.tsv.zst",
    output:
        "pre-processed/strains.txt",
    shell:
        """
        zstdcat {input.metadata} | \
        awk -F'\t' '{{print $1}}' > {output} 
        """


rule join_meta_nextclade:
    input:
        open_pango_metadata=rules.get_designated_metadata.output.metadata,
    output:
        "pre-processed/full_sequence_details.tsv.zst",
    shell:
        """
        zstcat {input} | \
        tsv-select -H -f strain,pango_designated,deletions,insertions,substitutions > meta_muts.tsv

        aws s3 cp s3://nextstrain-ncov-private/nextclade.tsv.gz - \
            | zcat -d \
            | tsv-select -H -f seqName,missing,alignmentStart,alignmentEnd \
            | tsv-join -H -f meta_muts.tsv -k 1 -a 2-5 \
            | zstd -o {output}
        rm meta_muts.tsv
        """


rule lineage_stats:
    input:
        reference="references/MN908947/reference.fasta",
        meta=rules.join_meta_nextclade.output,
    output:
        outfile="pre-processed/pango_matrix.npz",
    log:
        "logs/lineage_stats.txt",
    shell:
        """
        zstdcat {input.meta} | \
        python3 scripts/lineage_matrix.py \
            --ref {input.reference} \
            --meta /dev/stdin \
            --out {output.outfile} \
            2>&1 | tee {log} 
        """


rule make_synthetic_pangos:
    input:
        reference="references/MN908947/reference.fasta",
        matrix=rules.lineage_stats.output.outfile,
        alias=rules.download_pango_alias.output,
        overwrites="profiles/clades/lineage_overwrite.tsv",
    output:
        outfile="pre-processed/synthetic.fasta",
    log:
        "logs/make_synthetic_pangos.txt",
    shell:
        """
        python3 scripts/create_synthetic.py \
            --ref {input.reference} \
            --matrix {input.matrix} \
            --alias {input.alias} \
            --overwrites {input.overwrites} \
            --out {output.outfile} \
            2>&1 | tee {log} 
        """
