# Local upload page for time card files (Excel or CSV exported from Raken).
#
# Serves upload/index.html at http://localhost:<port>/ and passes the page's
# requests on to Supabase with the project's secret key. The key stays in this
# process; the browser never sees it. Only this computer can open the page.
#
# Needs the Supabase CLI, logged in and linked to this project (see CLAUDE.md).
# Raken is not involved: nothing here talks to Raken.
param([int]$Port = 4174, [switch]$NoBrowser)

$root = [System.IO.Path]::GetFullPath($PSScriptRoot)
$repo = Split-Path $root -Parent
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Started from another program, some user folders may be missing from the
# environment; the Supabase CLI needs them to find its login.
foreach ($pair in @(@('USERPROFILE', 'UserProfile'), @('LOCALAPPDATA', 'LocalApplicationData'), @('APPDATA', 'ApplicationData'))) {
  if (-not [Environment]::GetEnvironmentVariable($pair[0])) {
    [Environment]::SetEnvironmentVariable($pair[0], [Environment]::GetFolderPath($pair[1]))
  }
}
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$supabase = (Get-Command supabase -ErrorAction SilentlyContinue).Source
if (-not $supabase) {
  $supabase = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\supabase\supabase.exe'
}

$refFile = Join-Path $repo 'supabase\.temp\project-ref'
$projectRef = if (Test-Path $refFile) { (Get-Content $refFile -Raw).Trim() } else { 'hedpqzmsbtymuvqbxrqg' }

Write-Host 'Connecting to Supabase...'
$secretKey = $null
$cliErrors = @()
if (Test-Path $supabase) {
  $output = & $supabase projects api-keys --project-ref $projectRef --reveal -o json 2>&1
  $cliErrors = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() })
  try {
    $keys = (($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n") | ConvertFrom-Json
    $secretKey = ($keys | Where-Object { $_.type -eq 'secret' } | Select-Object -First 1).api_key
  } catch {
    $secretKey = $null
  }
} else {
  $cliErrors = @("Supabase CLI not found at $supabase")
}
if (-not $secretKey) {
  Write-Host 'Could not get the Supabase key. Check that the Supabase CLI is installed and logged in (supabase login).'
  if ($cliErrors) { Write-Host ('Supabase CLI: ' + ($cliErrors -join ' ')) }
  exit 1
}

# The page gets this token; requests without it are refused, so no other
# website open in the browser can use this server.
$tokenBytes = New-Object byte[] 24
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($tokenBytes)
$sessionToken = [Convert]::ToBase64String($tokenBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
$uploader = [Environment]::UserName

# The only Supabase calls the page may make.
$routes = @{
  'POST /api/import'  = '/rest/v1/rpc/import_time_cards'
  'POST /api/undo'    = '/rest/v1/rpc/undo_import'
  'GET /api/history'  = '/rest/v1/import_history?select=*&order=id.desc&limit=25'
}

function Invoke-Supabase([string]$Method, [string]$Path, [byte[]]$Body) {
  try {
    $request = [System.Net.HttpWebRequest]::Create("https://$projectRef.supabase.co$Path")
    $request.Method = $Method
    $request.Accept = 'application/json'
    $request.Headers.Add('apikey', $secretKey)
    $request.Timeout = 300000
    $request.ReadWriteTimeout = 300000
    if ($Body) {
      $request.ContentType = 'application/json; charset=utf-8'
      $request.ContentLength = $Body.Length
      $stream = $request.GetRequestStream()
      $stream.Write($Body, 0, $Body.Length)
      $stream.Close()
    }
    try {
      $response = $request.GetResponse()
    } catch {
      $ex = $_.Exception
      while ($ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
      if (-not $ex -or -not $ex.Response) { throw }
      $response = $ex.Response
    }
    $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd()
    $reader.Close()
    $status = [int]$response.StatusCode
    $response.Close()
    return @{ Status = $status; Body = $text }
  } catch {
    return @{ Status = 502; Body = (@{ message = "Could not reach Supabase: $($_.Exception.Message)" } | ConvertTo-Json -Compress) }
  }
}

function Send-Response($Response, [int]$Status, [string]$ContentType, [string]$Text) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $Response.StatusCode = $Status
  $Response.ContentType = $ContentType
  $Response.Headers['Cache-Control'] = 'no-store'
  $Response.Headers['X-Content-Type-Options'] = 'nosniff'
  $Response.ContentLength64 = $bytes.Length
  $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
try {
  $listener.Start()
} catch {
  Write-Host "Could not start on port $Port. Is the upload page already open in another window?"
  exit 1
}

$pageUrl = "http://localhost:$Port/"
$indexPath = Join-Path $root 'index.html'
Write-Host "Upload page: $pageUrl"
Write-Host 'Keep this window open while you use the page. Close it to stop.'
if (-not $NoBrowser) { Start-Process $pageUrl }

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response
    try {
      $route = "$($request.HttpMethod) $($request.Url.AbsolutePath)"
      if ($route -eq 'GET /' -or $route -eq 'GET /index.html') {
        $html = [System.IO.File]::ReadAllText($indexPath, [System.Text.Encoding]::UTF8)
        $html = $html.Replace('__SESSION_TOKEN__', $sessionToken).Replace('__UPLOADED_BY__', [System.Net.WebUtility]::HtmlEncode($uploader))
        # The page may only talk to this server, so file contents can't be sent anywhere else.
        $response.Headers['Content-Security-Policy'] = "default-src 'none'; script-src 'unsafe-inline' https://cdn.sheetjs.com; style-src 'unsafe-inline'; connect-src 'self'; img-src data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
        Send-Response $response 200 'text/html; charset=utf-8' $html
      } elseif ($routes.ContainsKey($route)) {
        $origin = $request.Headers['Origin']
        if ($request.Headers['X-Session-Token'] -ne $sessionToken -or ($origin -and $origin -ne "http://localhost:$Port")) {
          Send-Response $response 403 'application/json; charset=utf-8' '{"message":"Not allowed"}'
        } elseif ($request.ContentLength64 -gt 50MB) {
          Send-Response $response 413 'application/json; charset=utf-8' '{"message":"The file is too large. Split it by date."}'
        } else {
          $body = $null
          if ($request.HttpMethod -eq 'POST') {
            $buffer = New-Object System.IO.MemoryStream
            $request.InputStream.CopyTo($buffer)
            $body = $buffer.ToArray()
          }
          $result = Invoke-Supabase $request.HttpMethod $routes[$route] $body
          Send-Response $response $result.Status 'application/json; charset=utf-8' $result.Body
        }
      } else {
        Send-Response $response 404 'text/plain; charset=utf-8' 'Not found'
      }
    } catch {
      try { Send-Response $response 500 'application/json; charset=utf-8' (@{ message = $_.Exception.Message } | ConvertTo-Json -Compress) } catch { }
    } finally {
      $response.Close()
    }
  }
} finally {
  $listener.Stop()
}
