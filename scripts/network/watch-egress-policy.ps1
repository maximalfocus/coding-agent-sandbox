# Egress watcher host classification. Dot-sourced by watch-egress.ps1 and its regression test.

# Risk verdict: returns 'allow' | 'reject' | 'review' | 'gray'.
# Broad multi-tenant namespaces are review-only and must never enter unattended assessment.
function Get-EgressVerdict([string]$h) {
    # A trailing root dot is DNS-equivalent to the bare name ("host." == "host") and must not
    # dodge the verdict; -match below is already case-insensitive, mirroring the Bash twin's
    # lowercasing (and tinyproxy's case-insensitive filter matching).
    $h = $h -replace '\.$',''
    if ($h -match '^[0-9]+(\.[0-9]+){3}$') { return 'reject' }   # IP literal incl. metadata 169.254.x
    $reject = @(
        '(^|\.)doubleclick\.net$', '\.googlesyndication\.com$', '\.googleadservices\.com$', '^googleads\.',
        '\.google-analytics\.com$', '\.analytics\.google\.com$', '\.googletagmanager\.com$', '\.umami\.is$',
        '^mtalk\.google\.com$', '^metadata\.google\.internal$', '\.metadata\.goog$')
    foreach ($p in $reject) { if ($h -match $p) { return 'reject' } }
    $review = @(
        '(^|\.)storage\.googleapis\.com$', '(^|\.)drive\.google\.com$',
        '\.googleapis\.com$', '\.pkg\.dev$')
    foreach ($p in $review) { if ($h -match $p) { return 'review' } }
    $allow = @(
        '(^|\.)gstatic\.com$', '(^|\.)ggpht\.com$', '(^|\.)googlevideo\.com$', '(^|\.)ytimg\.com$',
        '^dl\.google\.com$', '^accounts\.google\.com$', '\.developers\.google\.com$', '^ai\.google\.dev$',
        '^pypi\.org$', '(^|\.)pythonhosted\.org$', '(^|\.)pypa\.io$', '(^|\.)crates\.io$',
        '^static\.rust-lang\.org$', '^rustup\.rs$', '^cdn\.playwright\.dev$', '^astral\.sh$')
    foreach ($p in $allow) { if ($h -match $p) { return 'allow' } }
    return 'gray'
}
