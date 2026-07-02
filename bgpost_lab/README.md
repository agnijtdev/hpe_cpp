# BGPoST Lab: Secure Transport for BGP Experiments

This repository contains a Docker-based experimental lab inspired by the paper "The Multiple Benefits of a Secure Transport for BGP".

The project compares BGP behavior over multiple transport/security modes:

- TCP
- TLS
- QUIC
- TLS with static TCP-AO-style authentication
- TLS with dynamic TCP-AO-style authentication

## Experiments Implemented

### Prefix Propagation Experiment

A 10-router BGP chain/loop is created. ExaBGP injects generated prefixes, and the receiving router writes MRT logs. The MRT output is parsed to compare prefix propagation delay across modes.


## Final Result Folders

Important final outputs are kept in:

- `results/final_5_mode_graphs_5000_announce50_delay15/`
- `results/generated_convergence_boxplot_10000_delay0/`
- `results/final_5_mode_graphs_observed_13104_announce50_delay15/`

Large raw MRT files,temporary generated configs, certificates, and runtime outputs are intentionally not committed.

## Notes

The RIPE RIS full-table experiment was attempted but not used as a final result because it was too heavy for the laptop-based Docker setup and did not produce reliable monitor output.

