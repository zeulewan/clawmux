# Vision Roadmap

Long-term phases for federation, trust, and next-gen version control. These build on top of the current release roadmap.

## Phase 1 — Foundation

- [x] REST messaging unification on voice hub — unified `send`/`wait` commands (v0.6.0)
- [ ] A2A-compatible endpoints on the hub
- [ ] Agent Manifests for discovery

## Phase 2 — Trust Layer

- [ ] Keypair generation and message signing
- [ ] Trust tiers implementation (cold message through raw access)
- [ ] Signed trust ledger (append-only, verifiable)
- [ ] Structured gateway for non-inner-circle agents

## Phase 3 — Federation

- [ ] Remote agent discovery across hubs
- [ ] Cross-hub messaging via A2A
- [ ] OpenClaw A2A extension
- [ ] Cold message flow (anyone can reach out, human reviews)

## Phase 4 — Reputation

- [ ] Trust dilution mechanism
- [ ] Dynamic trust scoring (agents recommend tier changes)
- [ ] Competence tracking per domain
- [ ] Model safety signal verification
- [ ] Extensible signal plugin model

## Phase 5 — Version Control

- [ ] CRDT-based real-time collaborative editing prototype
- [ ] Checkpoint model (replace commits)
- [ ] Reconciliation agent for live conflict resolution
- [ ] Trust-based access control for code changes
- [ ] Instant checkpoint propagation

## Phase 6 — Cryptographic Verification

- [ ] Zero-knowledge proofs for trust claims
- [ ] Merkle tree for trust relationship verification
- [ ] Signed chain of provenance for all messages
- [ ] API attestation for model identity verification
