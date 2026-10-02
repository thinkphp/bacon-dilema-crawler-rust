# Dilema Veche Author Crawler

A Rust CLI that lists the articles shown on
[Teodor Baconschi's author page](https://www.dilema.ro/autor/teodor-baconschi), fetches a
selected article for a preview of up to 120 words, or opens the original article
in a browser. The full article remains on Dilema Veche.

## Running

Install Rust and Cargo, then run from this directory:

```sh
cargo run
```

Available commands:

```sh
cargo run -- --list
cargo run -- --preview 1
cargo run -- --open 1
cargo run -- --help
```

The first run downloads the Rust dependencies. The crawler fetches the author
page and downloads an article only when you request a preview; it does not
crawl the entire site automatically. The list contains the articles present in
the author page's HTML when you run it.

In interactive mode, after selecting an article, choose `p` for a preview or
`o` to open the original page. Opening a page uses `xdg-open` on Linux.

Please respect Dilema Veche's `robots.txt` and terms if you extend the crawler
or run it frequently. The preview is intentionally short and links to the
original article.
