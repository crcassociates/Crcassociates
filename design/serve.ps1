# Serves this folder at http://localhost:<port>/ so the UI prototype can be
# opened in a browser pane. Local only; stop with Ctrl+C.
# Not required: ui-prototype.html also works when opened directly in a browser.
param([int]$Port = 4173)

$root = [System.IO.Path]::GetFullPath($PSScriptRoot)
$types = @{
  '.html' = 'text/html; charset=utf-8'
  '.md'   = 'text/plain; charset=utf-8'
  '.css'  = 'text/css; charset=utf-8'
  '.js'   = 'text/javascript; charset=utf-8'
  '.svg'  = 'image/svg+xml'
  '.png'  = 'image/png'
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Serving $root at http://localhost:$Port/"

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    $response = $context.Response
    try {
      $relative = [Uri]::UnescapeDataString($context.Request.Url.AbsolutePath).TrimStart('/')
      if ($relative -eq '') { $relative = 'ui-prototype.html' }
      $path = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $relative))
      # Only files inside this folder, only GET.
      $inside = $path.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
      if ($context.Request.HttpMethod -eq 'GET' -and $inside -and [System.IO.File]::Exists($path)) {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
        $response.ContentType = if ($types.ContainsKey($ext)) { $types[$ext] } else { 'application/octet-stream' }
        $response.Headers['Cache-Control'] = 'no-store'
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
      } else {
        $response.StatusCode = 404
      }
    } finally {
      $response.Close()
    }
  }
} finally {
  $listener.Stop()
}
