Output urlparse.gif
Set FontSize 14
Set Width 900
Set Height 700
Set Theme "Catppuccin Mocha"
Set Padding 12

Hide
Type "zig build"
Enter
Type "alias urlparse=./zig-out/bin/urlparse"
Enter
Type "clear"
Enter
Show

# Plain text output
Type "urlparse 'https://user:pass@example.com:8080/path?q=1&lang=en#top'"
Sleep 0.5s
Enter
Sleep 3s

# JSON output
Type "urlparse --json 'https://example.com/api?page=2&sort=name'"
Sleep 0.5s
Enter
Sleep 3s

# Field extraction
Type "urlparse --field host 'https://example.com/path'"
Sleep 0.5s
Enter
Sleep 2s
