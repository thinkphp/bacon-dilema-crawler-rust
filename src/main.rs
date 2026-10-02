use reqwest::blocking::Client;
use scraper::{Html, Selector};
use std::{
    collections::HashSet,
    env,
    error::Error,
    io::{self, Write},
    process::Command,
    time::Duration,
};
use url::Url;

const AUTHOR_URL: &str = "https://www.dilema.ro/autor/teodor-baconschi";
const PREVIEW_WORD_LIMIT: usize = 120;

#[derive(Debug)]
struct Article {
    title: String,
    url: Url,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("Eroare: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let args: Vec<String> = env::args().skip(1).collect();
    match args.as_slice() {
        [flag] if flag == "--help" || flag == "-h" => {
            print!("{USAGE}");
            Ok(())
        }
        [flag] if flag == "--list" => {
            let articles = load_articles()?;
            print_articles(&articles);
            Ok(())
        }
        [flag, raw_index] if flag == "--preview" => {
            let index = parse_index(raw_index)?;
            let articles = load_articles()?;
            preview_selected(index, &articles)
        }
        [flag, raw_index] if flag == "--open" => {
            let index = parse_index(raw_index)?;
            let articles = load_articles()?;
            open_selected(index, &articles)
        }
        [] => {
            let articles = load_articles()?;
            interactive(&articles)
        }
        _ => {
            eprint!("{USAGE}");
            Err("Argumente invalide.".into())
        }
    }
}

fn http_client() -> Result<Client, reqwest::Error> {
    Client::builder()
        .timeout(Duration::from_secs(20))
        .user_agent("DilemaCrawler/0.1 (personal reading project)")
        .build()
}

fn fetch_html(client: &Client, url: &Url) -> Result<String, Box<dyn Error>> {
    let response = client.get(url.clone()).send()?.error_for_status()?;
    Ok(response.text()?)
}

fn load_articles() -> Result<Vec<Article>, Box<dyn Error>> {
    let author_url = Url::parse(AUTHOR_URL)?;
    let html = fetch_html(&http_client()?, &author_url)?;
    let articles = extract_articles(&html, &author_url);
    if articles.is_empty() {
        return Err(
            "Nu am găsit articole pe pagina autorului; structura site-ului se poate să se fi schimbat."
                .into(),
        );
    }
    Ok(articles)
}

fn extract_articles(html: &str, author_url: &Url) -> Vec<Article> {
    let document = Html::parse_document(html);
    let selector =
        Selector::parse("a.link_image.featured-thumbnail[title][href]").expect("selector is valid");
    let mut seen_urls = HashSet::new();
    let mut articles = Vec::new();

    for anchor in document.select(&selector) {
        let title = anchor
            .value()
            .attr("title")
            .map(normalize_text)
            .unwrap_or_default();
        let Some(href) = anchor.value().attr("href") else {
            continue;
        };
        let Ok(url) = author_url.join(href) else {
            continue;
        };
        if title.is_empty()
            || url.scheme() != "https"
            || url.host_str() != author_url.host_str()
            || url.path() == author_url.path()
            || !seen_urls.insert(url.as_str().to_owned())
        {
            continue;
        }
        articles.push(Article { title, url });
    }

    articles
}

fn print_articles(articles: &[Article]) {
    for (index, article) in articles.iter().enumerate() {
        println!("{}. {}", index + 1, article.title);
    }
}

fn preview_selected(index: usize, articles: &[Article]) -> Result<(), Box<dyn Error>> {
    let article = get_article(index, articles)?;
    let html = fetch_html(&http_client()?, &article.url)?;
    let document = Html::parse_document(&html);
    let title_selector = Selector::parse("h1").expect("selector is valid");
    let paragraph_selector = Selector::parse(".post_content p").expect("selector is valid");

    let title = document
        .select(&title_selector)
        .next()
        .map(|element| normalize_text(&element.text().collect::<String>()))
        .filter(|text| !text.is_empty())
        .unwrap_or_else(|| article.title.clone());
    let words: Vec<String> = document
        .select(&paragraph_selector)
        .flat_map(|paragraph| {
            paragraph
                .text()
                .collect::<String>()
                .split_whitespace()
                .map(str::to_owned)
                .collect::<Vec<_>>()
        })
        .take(PREVIEW_WORD_LIMIT)
        .collect();
    if words.is_empty() {
        return Err(
            "Nu am putut extrage textul eseului; structura paginii se poate să se fi schimbat."
                .into(),
        );
    }

    println!("\n{title}\n");
    println!("{}", words.join(" "));
    println!(
        "\n[Preview limitat la {PREVIEW_WORD_LIMIT} de cuvinte. Citește eseul complet pe site.]"
    );
    println!("{}", article.url);
    Ok(())
}

fn open_selected(index: usize, articles: &[Article]) -> Result<(), Box<dyn Error>> {
    open_article(get_article(index, articles)?)
}

fn interactive(articles: &[Article]) -> Result<(), Box<dyn Error>> {
    print_articles(articles);
    println!("\nAlege numărul articolului sau q pentru ieșire:");
    let choice = read_line()?;
    if choice.eq_ignore_ascii_case("q") {
        return Ok(());
    }

    let index = match parse_index(&choice) {
        Ok(index) => index,
        Err(_) => {
            println!("Alegere invalidă.");
            return Ok(());
        }
    };
    let article = match get_article(index, articles) {
        Ok(article) => article,
        Err(_) => {
            println!(
                "Număr invalid. Alege un articol între 1 și {}.",
                articles.len()
            );
            return Ok(());
        }
    };

    println!("Alege acțiunea: p = preview, o = deschide în browser, q = ieșire");
    match read_line()?.as_str() {
        "p" => preview_selected(index, articles),
        "o" => open_article(article),
        _ => Ok(()),
    }
}

fn open_article(article: &Article) -> Result<(), Box<dyn Error>> {
    let status = Command::new("xdg-open")
        .arg(article.url.as_str())
        .status()?;
    if !status.success() {
        return Err(format!(
            "Browserul nu s-a putut deschide (xdg-open a ieșit cu codul {}).",
            status.code().unwrap_or(-1)
        )
        .into());
    }
    println!("Am deschis articolul în browser: {}", article.url);
    Ok(())
}

fn get_article(index: usize, articles: &[Article]) -> Result<&Article, Box<dyn Error>> {
    index
        .checked_sub(1)
        .and_then(|zero_based_index| articles.get(zero_based_index))
        .ok_or_else(|| {
            format!(
                "Număr invalid. Alege un articol între 1 și {}.",
                articles.len()
            )
            .into()
        })
}

fn parse_index(value: &str) -> Result<usize, Box<dyn Error>> {
    let index = value.parse::<usize>()?;
    if index == 0 {
        return Err("Numărul articolului trebuie să fie cel puțin 1.".into());
    }
    Ok(index)
}

fn normalize_text(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn read_line() -> io::Result<String> {
    let mut input = String::new();
    io::stdout().flush()?;
    io::stdin().read_line(&mut input)?;
    Ok(input.trim().to_owned())
}

const USAGE: &str = "Utilizare:\n\
  cargo run                 Listează articolele și permite alegerea unui preview\n\
  cargo run -- --list       Listează articolele\n\
  cargo run -- --preview N  Afișează preview-ul articolului N\n\
  cargo run -- --open N     Deschide articolul N în browser\n\
  cargo run -- --help\n";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_unique_article_links_from_author_page() {
        let author_url = Url::parse(AUTHOR_URL).unwrap();
        let html = r#"
            <section class="container">
                <div class="entry">
                    <a class="link_image featured-thumbnail" title="Titlu test" href="/opinii/articol-1"></a>
                </div>
                <div class="entry">
                    <a class="link_image featured-thumbnail" title="Duplicat" href="/opinii/articol-1"></a>
                    <a class="link_image featured-thumbnail" title="Ignorat" href="https://example.com/fals"></a>
                </div>
            </section>
        "#;

        let articles = extract_articles(html, &author_url);

        assert_eq!(articles.len(), 1);
        assert_eq!(articles[0].title, "Titlu test");
        assert_eq!(
            articles[0].url.as_str(),
            "https://www.dilema.ro/opinii/articol-1"
        );
    }

    #[test]
    fn parses_only_positive_article_numbers() {
        assert_eq!(parse_index("12").unwrap(), 12);
        assert!(parse_index("0").is_err());
        assert!(parse_index("x").is_err());
    }

    #[test]
    fn normalizes_whitespace() {
        assert_eq!(normalize_text(" Titlu \n cu   spații "), "Titlu cu spații");
    }
}
