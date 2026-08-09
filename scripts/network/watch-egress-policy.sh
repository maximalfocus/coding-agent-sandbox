#!/usr/bin/env bash
# Egress watcher host classification. Sourced by watch-egress.sh and its regression test.

# Risk verdict for a host: echoes allow | reject | review | gray.
# Broad multi-tenant namespaces are review-only and must never enter unattended assessment.
classify_egress_host() {
    local h="$1"
    # Normalize DNS-equivalent variants before classifying: hostnames are case-insensitive
    # (tinyproxy's filter matching is case-insensitive too, and the PS twin's -match is
    # case-insensitive), and a trailing root dot ("host." == "host") must not dodge the verdict.
    h="$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')"
    h="${h%.}"
    # IP literal (covers the 169.254.x metadata endpoint and any direct-IP attempt)
    if [[ "$h" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then echo reject; return; fi
    case "$h" in
        # --- REJECT: trackers / ads / metadata / background phone-home ---
        *doubleclick.net|*.googlesyndication.com|*.googleadservices.com|googleads.*|\
        *.google-analytics.com|*.analytics.google.com|*.googletagmanager.com|*.umami.is|\
        mtalk.google.com|metadata.google.internal|*.metadata.goog)
            echo reject; return ;;
        # --- REVIEW: broad / multi-tenant capability grants -> always require a human ---
        storage.googleapis.com|*.storage.googleapis.com|drive.google.com|*.drive.google.com|\
        *.googleapis.com|*.pkg.dev)
            echo review; return ;;
        # --- ALLOW: first-party read-only CDNs / docs / package indexes / exact services ---
        gstatic.com|*.gstatic.com|ggpht.com|*.ggpht.com|\
        googlevideo.com|*.googlevideo.com|ytimg.com|*.ytimg.com|dl.google.com|\
        accounts.google.com|*.developers.google.com|ai.google.dev|\
        pypi.org|files.pythonhosted.org|*.pythonhosted.org|pypa.io|*.pypa.io|\
        crates.io|*.crates.io|static.rust-lang.org|rustup.rs|cdn.playwright.dev|astral.sh)
            echo allow; return ;;
    esac
    echo gray
}
