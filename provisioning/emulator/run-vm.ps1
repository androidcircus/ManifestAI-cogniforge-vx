# provisioning/emulator/run-vm.ps1
# QEMU emulator entry point (Windows edition) - boots a VM from an ISO and
# attaches a virtual GPU (virtio-gpu).
#
# Usage (PowerShell):
#   $env:ISO = "C:\isos\ubuntu-24.04.2-live-server-amd64.iso"
#   .\run-vm.ps1 cogniforge-worker-01
#
# Install QEMU on Windows first (e.g. via winget), or use the MSYS2 source
# build from README.md (binary installed at C:\msys64\mingw64\qemu-system-x86_64.exe):
#   winget install -e --id SoftwareFreedomConservancy.QEMU
#
# Optional: attach the custom cogniforge-gpu device.
#   $env:COGNIFORGE = "1"                     # use defaults (sm_count=256, vram 2GiB)
#   $env:COGNIFORGE_SM_COUNT = 256
#   $env:COGNIFORGE_VRAM = 268435456          # plain integer; M/G suffixes rejected

param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$Name
)

$QEMU = $env:QEMU
if (-not $QEMU) { $QEMU = "qemu-system-x86_64.exe" }
if (Get-Command $QEMU -ErrorAction SilentlyContinue) { }
else {
  $candidates = @(
    "C:\Program Files\qemu\qemu-system-x86_64.exe",
    "$env:LOCALAPPDATA\Programs\qemu\qemu-system-x86_64.exe",
    "C:\msys64\mingw64\qemu-system-x86_64.exe",
    "C:\msys64\mingw64\bin\qemu-system-x86_64.exe"
  )
  $found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($found) { $QEMU = $found } else { throw "QEMU not found. Set `$env:QEMU or run: winget install SoftwareFreedomConservancy.QEMU" }
}

# The MSYS2 build must run from the prefix root so its compiled-in datadir
# resolves; if a copy was dropped into mingw64\bin, its relocated datadir is
# wrong and the BIOS fails to load - force it with -L.
$qemuDataDir = @()
if ($QEMU -eq "C:\msys64\mingw64\qemu-system-x86_64.exe" -or
    $QEMU -eq "C:\msys64\mingw64\bin\qemu-system-x86_64.exe") {
  # MSYS2-built exe depends on DLLs in mingw64\bin (glib, pixman, ...); make
  # sure they resolve when launched from a plain Windows shell.
  $env:Path = "C:\msys64\mingw64\bin;$env:Path"
}
if ($QEMU -eq "C:\msys64\mingw64\bin\qemu-system-x86_64.exe") {
  $qemuDataDir = @("-L", "C:/msys64/mingw64/share")
}

$ISO  = $env:ISO
if (-not $ISO) { throw "Set `$env:ISO to the installer ISO path" }

$RAM    = if ($env:RAM)   { [int]$env:RAM   } else { 131072 }
$VCPU   = if ($env:VCPU)  { [int]$env:VCPU  } else { 16 }
$VRAM   = if ($env:VRAM)  { [int]$env:VRAM  } else { 512 }
$Disk   = if ($env:DISK)  { $env:DISK       } else { (Join-Path (Get-Location) "$Name.qcow2") }
$DiskSize = if ($env:DISK_SIZE) { $env:DISK_SIZE } else { "40G" }
$Display = if ($env:DISPLAY) { $env:DISPLAY } else { "vnc=:1" }

# Optional custom compute accelerator
$cogniforge = @()
if ($env:COGNIFORGE) {
  $smCount = if ($env:COGNIFORGE_SM_COUNT) { [int]$env:COGNIFORGE_SM_COUNT } else { 256 }
  $vram    = if ($env:COGNIFORGE_VRAM)    { [int64]$env:COGNIFORGE_VRAM }    else { 2147483648 }
  $cogniforge = @("-device", "cogniforge-gpu,sm_count=$smCount,vram_size=$vram")
}

if (-not (Test-Path $Disk)) {
  Write-Host "==> Creating disk image $Disk"
  & (Join-Path (Split-Path $QEMU) "qemu-img.exe") create -f qcow2 $Disk $DiskSize
}

$args = @(
  "-name", $Name, "-machine", "q35", "-m", $RAM, "-smp", $VCPU,
  "-drive", "file=$Disk,if=virtio,format=qcow2",
  "-cdrom", $ISO, "-boot", "d",
  "-device", "virtio-gpu-pci,id=gpu0,hostmem=${VRAM}M,max_hostmem=4096M",
  "-device", "virtio-mouse-pci", "-device", "virtio-keyboard-pci",
  "-netdev", "user,id=net0", "-device", "virtio-net-pci,netdev=net0",
  "-display", $Display
) + $cogniforge + $qemuDataDir

Write-Host "==> Launching $Name ($QEMU)"
& $QEMU $args
