# BGPoST Lab: Secure Transport for BGP Experiments

This repository contains a Docker-based experimental lab inspired by the paper "The Multiple Benefits of a Secure Transport for BGP".

The project compares BGP behavior over multiple transport/security modes:

- TCP
- TLS
- QUIC
- TLS with static TCP-AO-style authentication
- TLS with dynamic TCP-AO-style authentication

## Experiments Implemented

### 1. Prefix Propagation Experiment

A 10-router BGP chain/loop is created. ExaBGP injects generated prefixes, and the receiving router writes MRT logs. The MRT output is parsed to compare prefix propagation delay across modes.

### 2. Generated-Prefix Convergence Experiment

A smaller topology is used:

Injecter → R1 → R2 → Monitor

Generated prefixes are injected, and the monitor records received updates in MRT format. This is used to compare convergence behavior across transport modes.

## Final Result Folders

Important final outputs are kept in:

- `results/final_5_mode_graphs_5000_announce50_delay15/`
- `results/generated_convergence_boxplot_10000_delay0/`
- `results/final_5_mode_graphs_observed_13104_announce50_delay15/`

Large raw MRT files, RIPE RIS dumps, temporary generated configs, certificates, and runtime outputs are intentionally not committed.

## Notes

The RIPE RIS full-table experiment was attempted but not used as a final result because it was too heavy for the laptop-based Docker setup and did not produce reliable monitor output.

## Author

Gopika Sreekumar
