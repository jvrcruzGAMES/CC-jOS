-- CC-jOS Root Authority Signing Key (RSA-512 / SHA-256)
-- Used by tools/jos-sign.lua to sign bootloader, kernel, and .app bundles.

return {
    keyId = "CC-jOS-Root-CA-v1",
    algorithm = "RSA-SHA256",
    n = "9bd6755d0f32ec7f7b09e4419c66c220fd2b7eaeaee019735c2dc1af6644d098d0ed2f9e41dfc720ed770b0959af3b64ba18a244a30c18a41a8013f85088a559",
    e = "010001",
    d = "46ef1456fa9f1c655e94ff101a67efbf625dd4f92062a3530e47499d5438c895c0d5c3488d316261cdc26583473d863a303cd0f2a340eac8e3f9a1b95ee4416d"
}
