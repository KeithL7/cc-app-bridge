param(
  [int]$Left = 0,
  [int]$Top = 0,
  [int]$Width = 0,
  [int]$Height = 0,
  [string]$Path,
  [string]$Format = 'png',
  [int]$Quality = 80
)
# Standalone one-shot screen grab. Kept isolated and minimal on purpose.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Drawing

$img = New-Object System.Drawing.Bitmap($Width, $Height)
$gfx = [System.Drawing.Graphics]::FromImage($img)
$gfx.CopyFromScreen($Left, $Top, 0, 0, $img.Size)
$gfx.Dispose()

$fmt = $Format.ToLower()
if ($fmt -eq 'jpeg' -or $fmt -eq 'jpg') {
  $enc = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
  $eps = New-Object System.Drawing.Imaging.EncoderParameters(1)
  $eps.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [int64]$Quality)
  $img.Save($Path, $enc, $eps)
} else {
  $img.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
}
$img.Dispose()

$size = (Get-Item $Path).Length
[Console]::Out.WriteLine((@{ path = $Path; sizeBytes = $size } | ConvertTo-Json -Compress))
