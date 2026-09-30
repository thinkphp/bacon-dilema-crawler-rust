# Dilema.ro Author Crawler

A small Haskell CLI that reads the article titles displayed on Andrei Pleșu's
author page and can fetch a selected essay to show a preview of up to 120 words.
The full essay remains on Dilema.ro.

## Running

GHC, Cabal, and the `curl` utility are required. From this directory, run:

```sh
cabal run dilema-crawler
```

Available commands:

```sh
cabal run dilema-crawler -- --list
cabal run dilema-crawler -- --preview 1
cabal run dilema-crawler -- --open 1
cabal run dilema-crawler -- --help
```

On the first run, Cabal downloads the dependencies (`tagsoup` and `text`). The
crawler uses `curl` for HTTPS requests. It fetches the author page and downloads
an essay page only when you request a preview; it does not crawl the entire
site automatically. The author page currently has no working pagination in its
HTML, so the list includes the articles shown on the page at the time you run
the crawler.

In interactive mode, after selecting an article, you can choose to view its
preview or open the original page in your browser. The `--open N` command uses
`xdg-open` on Linux.

Please respect Dilema.ro's `robots.txt` and terms if you extend the crawler or
run it frequently. The preview is intentionally short and links to the
original article.
