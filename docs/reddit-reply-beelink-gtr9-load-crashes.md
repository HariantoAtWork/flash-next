# Reddit reply — Beelink GTR9 Pro load-time crashes

Draft answer to a Redditor chasing load-time crashes on a Beelink GTR9 Pro
(`gfx1151`), who asked about hardware/BIOS, fabric sync floods, load count, and
whether `fork-enhancements` changes the weight loader.

Fill in the two `[…]` placeholders before posting.

---

Thanks — and fair questions. I’m not on a Beelink myself; this stack was
built/run on a **GPD G1618-05** (Strix Halo): **Ryzen AI MAX+ 395 / Radeon 8060S
(`gfx1151`)**, BIOS **AMI 2.23 (2025-11-28)**, host is **NixOS**, container uses
**ROCm 7.2.4**. So take hardware/BIOS notes as “works here”, not “same as GTR9
Pro”.

**Full-machine reset / “data fabric sync flood”:**  
I haven’t been chasing that specifically on this box. Gufo’s own NPU docs do
warn that **letting the GPU fabric clock change while the NPU is busy can hang
the machine** — my compose defaults to **`GUFO_NPU=0` (GPU-only)**, so I’m not
holding/releasing fabric clock for NPU. If you’re enabling NPU on the GTR9, that
path is a more likely suspect than this Docker wiring. If you hit a reset, grab
`dmesg` after reboot (fabric / amdgpu / IOMMU) and we can compare.

**How many loads:**  
[e.g. dozens of cold starts over the last ~week on Flash-Next UD-IQ4_XS + MTP +
mmproj, no hard resets on this GPD]

**Does `fork-enhancements` change the weight loader?**  
From what’s in the image: **the O_DIRECT / `pread` → `hipMemcpyAsync` path is
already in gufo’s core** (`weight_upload.cpp`, plus related DirectIO use for
n-gram / identity reads). That doesn’t look like a fork-only invention. The fork
is mainly what this image builds (`mikealanni/gufo` @ `fork-enhancements`) with
**NPU compile enabled** (`GUFO_ENABLE_NPU=ON`) even when runtime stays GPU-only.
So for load-time crashes I’d treat **ROCm 7.2.4 + this gufo tree** as one combo,
not “fork specially rewrote the loader”.

If you’re crashing mid-load on the Beelink, things I’d try first: GPU-only
(`GUFO_NPU=0`), enough free unified RAM for the GGUF (UD-IQ4_XS Flash-Next isn’t
tiny), and check whether the crash correlates with NPU/fabric-clock scripts —
not with this repo’s compose helper.

Repo: https://github.com/HariantoAtWork/flash-next — newcomers can
`./dc.sh init` → edit `.env` → `./dc.sh download` → `./dc.sh up` (pulls the Hub
image; no local ROCm compile needed).
