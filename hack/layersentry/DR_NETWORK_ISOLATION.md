# DR network isolation

This workflow creates one internal Hyper-V switch for `layersentry-dr-rocky9` on
`10.10.20.0/24`, with the host endpoint at `10.10.20.1`. It deliberately does
not create a second WinNAT instance: Windows supports only one internal WinNAT
prefix per host. The guest must receive its address, DNS and routes explicitly.

Copy the example request, bind it to the exact VM, NIC, current switch and
original two-VM request digest, then commit it. Run `Preflight` first. Inspect
the evidence before separately authorizing `Apply`. The VM must be off for Apply
and Rollback. The protected journal records resource ownership before mutation.
Rollback reconnects the original switch and removes only resources created by
the journal; it never deletes the VM or disks.

The subnet is rejected if it overlaps any non-default host route, host address,
or WinNAT prefix. Guest connectivity and Rocky configuration remain `PENDING`
until tested after installation.
