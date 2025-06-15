# HTML links to files

## Purpose
A simple utility for scanning HTML files and downloading scripts from the links in `<script>` tags. <br> 
This tool can help analyze linked scripts (checking security, style guide compliance) and automate saving local copies of files hosted on CDNs.

### Core utilities:
- Work with local files and http links
- Ability to specify output path for downloaded scripts

### Limitations:
- Ignores relative links in script `src` attributes - <strong>TODO!</strong>
- Ignores local code inside `<script>` tag 
- One-threaded for now - <strong>TODO!</strong>

## Usage
This is a command-line tool. <br>
Download the appropriate version from the Releases tab and use it in the terminal.<br>
Development was done using Zig 0.15—you can also build the app manually using `zig build`.

## CLI settings:
<pre>
-h, --help      Display this help and exit
-f, --file      Path to HTML file with scripts-links. <strong>Use when -l doesn't set</strong>
-l, --link      Link to html page - search for scripts-links at given page. <strong>Use when -f doesn't set</strong>
-o, --output    Output path: 
    > If ends with "/" - creates dir "scripts" at given path; 
    > If ends with name - creates dir with that name at given path;
    > If doesn't set - - creates dir "scripts" at working path.
</pre>
---
*This is my first tool written in ZIG. I created it to learn the language more. (useful feeback is always welcome!)*