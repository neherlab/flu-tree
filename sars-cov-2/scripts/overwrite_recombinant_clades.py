import typer

# python scripts/overwrite_recombinant_clades.py \
# --clades {input.clades_json} \
# --output {output.clades_json}
def main(
    clades: str = "",
    internal_pango: str = "",
    output: str = "",
):
    import json

    # Load clades.json
    with open(clades, "r") as f:
        clades = json.load(f)

    with open(internal_pango, "r") as f:
        internal_pango = json.load(f)

    # Overwrite values with `recombinant` where `key` starts with X
    for node, value in clades["nodes"].items():
        if node.startswith("X") or internal_pango["nodes"].get(node,{}).get("Nextclade_pango","").startswith(
            "X"
        ):
            value["clade_membership"] = "recombinant"

    # Write clades.json
    with open(output, "w") as f:
        json.dump(clades, f, indent=2)


if __name__ == "__main__":
    typer.run(main)
    # for debugging
    # main(clades="builds/nextclade/clades.json", output="builds/nextclade/clades_with_recombinants.json")
