# Nextclade reference tree workflow for West Nile virus

This README doesn't end up in the datasets, so it's a developer README, rather than a dataset user README.

## Usage

```bash
snakemake
```

You need to have a `nextclade3` binary in your path. It's in the `nextstrain/docker-base` image or you can get it from <https://github.com/nextstrain/nextclade/releases/tag/3.0.0-alpha.0>.

### Visualize results

View results with:

```bash
nextstrain view auspice/
```

## Maintenance

### Updating for new clades

- [ ] Update each `config/{build}/clades.tsv` with new clades
- [ ] Add new clades to color ordering
- [ ] Check that clades look good, exclude problematic sequences as necessary

## Installation

Follow the [standard installation instructions](https://docs.nextstrain.org/en/latest/install.html) for Nextstrain's suite of software tools.

## Data use

We gratefully acknowledge the authors, originating and submitting laboratories of the genetic
sequences and metadata for sharing their work. Please note that although data generators have
generously shared data in an open fashion, that does not mean there should be free license to
publish on this data. Data generators should be cited where possible and collaborations should be
sought in some circumstances. Please try to avoid scooping someone else's work. Reach out if
uncertain.
