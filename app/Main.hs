{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (IOException, catch)
import Control.Monad (unless, when)
import qualified Data.ByteString as BS
import Data.List (find, isPrefixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding.Error as TEE
import Data.Text.Encoding (decodeUtf8With)
import System.Exit (ExitCode (..), exitFailure)
import System.Environment (getArgs)
import System.IO (Handle, hClose, hPutStrLn, hSetBinaryMode, stderr)
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , StdStream (..)
  , createProcess
  , proc
  , waitForProcess
  )
import Text.HTML.TagSoup
  ( Tag (..)
  , fromAttrib
  , innerText
  , parseTags
  )

authorUrl :: String
authorUrl = "https://www.dilema.ro/autor/andrei-plesu"

siteRoot :: String
siteRoot = "https://www.dilema.ro"

previewWordLimit :: Int
previewWordLimit = 120

data Article = Article
  { articleTitle :: T.Text
  , articleUrl :: String
  }

main :: IO ()
main = do
  args <- getArgs
  run args `catch` handleIOException

handleIOException :: IOException -> IO ()
handleIOException err = do
    hPutStrLn stderr ("Eroare: " ++ show err)
    exitFailure

run :: [String] -> IO ()
run ["--help"] = putStr usage
run ["-h"] = putStr usage
run ["--list"] = withArticles printArticles
run ["--preview", rawIndex] =
  case readInt rawIndex of
    Nothing -> invalidArguments
    Just index -> withArticles (previewSelected index)
run ["--open", rawIndex] =
  case readInt rawIndex of
    Nothing -> invalidArguments
    Just index -> withArticles (openSelected index)
run [] = withArticles interactive
run _ = invalidArguments

withArticles :: ([Article] -> IO ()) -> IO ()
withArticles action = do
  html <- fetchHtml authorUrl
  let articles = extractArticles (parseHtml html)
  when (null articles) $
    ioError (userError "Nu am găsit articole pe pagina autorului; structura site-ului se poate să se fi schimbat.")
  action articles

interactive :: [Article] -> IO ()
interactive articles = do
  printArticles articles
  putStrLn "\nAlege numărul articolului sau q pentru ieșire:"
  choice <- getLine
  unless (choice == "q" || choice == "Q") $
    case readInt choice of
      Nothing -> putStrLn "Alegere invalidă."
      Just index ->
        case atMay (index - 1) articles of
          Nothing -> putStrLn ("Număr invalid. Alege un articol între 1 și " ++ show (length articles) ++ ".")
          Just article -> do
            putStrLn "Alege acțiunea: p = preview, o = deschide în browser, q = ieșire"
            action <- getLine
            case action of
              "p" -> previewSelected index articles
              "o" -> openArticle article
              _ -> pure ()

printArticles :: [Article] -> IO ()
printArticles articles =
  mapM_ printArticle (zip [1 :: Int ..] articles)
  where
    printArticle (index, article) =
      putStrLn (show index ++ ". " ++ T.unpack (articleTitle article))

previewSelected :: Int -> [Article] -> IO ()
previewSelected index articles =
  case atMay (index - 1) articles of
    Nothing -> ioError (userError ("Număr invalid. Alege un articol între 1 și " ++ show (length articles) ++ "."))
    Just article -> do
      html <- fetchHtml (articleUrl article)
      let tags = parseHtml html
          pageTitle = extractTitle tags
          paragraphs = extractParagraphs (extractPostContent tags)
          preview = take previewWordLimit (concatMap T.words paragraphs)
          title = if T.null pageTitle then articleTitle article else pageTitle
      when (null preview) $
        ioError (userError "Nu am putut extrage textul eseului; structura paginii se poate să se fi schimbat.")
      putStrLn ("\n" ++ T.unpack title ++ "\n")
      putStrLn (T.unpack (T.unwords preview))
      putStrLn ("\n[Preview limitat la " ++ show previewWordLimit ++ " de cuvinte. Citește eseul complet pe site.]")
      putStrLn (articleUrl article)

openSelected :: Int -> [Article] -> IO ()
openSelected index articles =
  case atMay (index - 1) articles of
    Nothing -> ioError (userError ("Număr invalid. Alege un articol între 1 și " ++ show (length articles) ++ "."))
    Just article -> openArticle article

openArticle :: Article -> IO ()
openArticle article = do
  let url = articleUrl article
  (_, _, _, processHandle) <- createProcess (proc "xdg-open" [url])
  result <- waitForProcess processHandle
  case result of
    ExitSuccess -> putStrLn ("Am deschis articolul în browser: " ++ url)
    ExitFailure code ->
      ioError (userError ("Browserul nu s-a putut deschide (xdg-open a ieșit cu codul " ++ show code ++ ")."))

fetchHtml :: String -> IO T.Text
fetchHtml url = do
  let request = (proc "curl"
        [ "--fail"
        , "--location"
        , "--silent"
        , "--show-error"
        , "--max-time", "20"
        , "--proto", "=https"
        , "--user-agent", "DilemaCrawler/0.1 (personal reading project)"
        , url
        ]) { std_in = NoStream, std_out = CreatePipe, std_err = Inherit }
  (_, output, _, processHandle) <- createProcess request
  case output of
    Nothing -> ioError (userError "Nu s-a putut deschide fluxul de răspuns curl.")
    Just outputHandle -> readResponse outputHandle processHandle
  where
    readResponse :: Handle -> ProcessHandle -> IO T.Text
    readResponse outputHandle processHandle = do
      hSetBinaryMode outputHandle True
      body <- BS.hGetContents outputHandle
      hClose outputHandle
      result <- waitForProcess processHandle
      case result of
        ExitSuccess -> pure (decodeUtf8With TEE.lenientDecode body)
        ExitFailure code ->
          ioError (userError ("Descărcarea a eșuat cu codul curl " ++ show code ++ " pentru " ++ url))

parseHtml :: T.Text -> [Tag String]
parseHtml = parseTags . T.unpack

extractArticles :: [Tag String] -> [Article]
extractArticles = go
  where
    go [] = []
    go (TagOpen "h3" attrs : rest)
      | hasClass "h3" "image-post-title" attrs =
          let (heading, afterHeading) = break (isClosing "h3") rest
              article = articleFromHeading heading
          in maybe id (:) article (go (dropClosing afterHeading))
    go (_ : rest) = go rest

articleFromHeading :: [Tag String] -> Maybe Article
articleFromHeading tags = do
  (attrs, anchorContent) <- findAnchor tags
  let path = fromAttrib "href" (TagOpen "a" attrs)
      title = normalizeText (innerText anchorContent)
  if "/" `isPrefixOf` path && not ("//" `isPrefixOf` path) && not (T.null title)
    then Just (Article title (siteRoot ++ path))
    else Nothing

findAnchor :: [Tag String] -> Maybe ([(String, String)], [Tag String])
findAnchor tags = do
  TagOpen "a" attrs <- find isAnchor tags
  let afterOpen = dropWhile (not . isAnchor) tags
  case afterOpen of
    TagOpen "a" _ : rest ->
      let (content, _) = break (isClosing "a") rest
      in Just (attrs, content)
    _ -> Nothing
  where
    isAnchor (TagOpen "a" _) = True
    isAnchor _ = False

extractTitle :: [Tag String] -> T.Text
extractTitle tags =
  case findTagContent "h1" "single_post_title_main" tags of
    Nothing -> ""
    Just content -> normalizeText (innerText content)

extractPostContent :: [Tag String] -> [Tag String]
extractPostContent [] = []
extractPostContent (TagOpen "div" attrs : rest)
  | hasClass "div" "post_content" attrs = takeDivContents 1 [] rest
extractPostContent (_ : rest) = extractPostContent rest

takeDivContents :: Int -> [Tag String] -> [Tag String] -> [Tag String]
takeDivContents _ collected [] = reverse collected
takeDivContents depth collected (TagClose "div" : rest)
  | depth == 1 = reverse collected
  | otherwise = takeDivContents (depth - 1) (TagClose "div" : collected) rest
takeDivContents depth collected (TagOpen "div" attrs : rest)
  = takeDivContents (depth + 1) (TagOpen "div" attrs : collected) rest
takeDivContents depth collected (tag : rest) =
  takeDivContents depth (tag : collected) rest

extractParagraphs :: [Tag String] -> [T.Text]
extractParagraphs [] = []
extractParagraphs (TagOpen "p" _ : rest) =
  let (content, afterParagraph) = break (isClosing "p") rest
      paragraph = normalizeText (innerText content)
  in [paragraph | not (T.null paragraph)] ++ extractParagraphs (dropClosing afterParagraph)
extractParagraphs (_ : rest) = extractParagraphs rest

findTagContent :: String -> String -> [Tag String] -> Maybe [Tag String]
findTagContent _ _ [] = Nothing
findTagContent name className (TagOpen tagName attrs : rest)
  | tagName == name && hasClass tagName className attrs =
      Just (takeWhile (not . isClosing name) rest)
findTagContent name className (_ : rest) = findTagContent name className rest

hasClass :: String -> String -> [(String, String)] -> Bool
hasClass tagName className attrs =
  className `elem` words (fromAttrib "class" (TagOpen tagName attrs))

normalizeText :: String -> T.Text
normalizeText = T.unwords . T.words . T.pack

isClosing :: String -> Tag String -> Bool
isClosing name (TagClose tagName) = name == tagName
isClosing _ _ = False

dropClosing :: [Tag String] -> [Tag String]
dropClosing [] = []
dropClosing (_ : rest) = rest

atMay :: Int -> [a] -> Maybe a
atMay index values
  | index < 0 = Nothing
  | otherwise = case drop index values of
      value : _ -> Just value
      [] -> Nothing

readInt :: String -> Maybe Int
readInt value = case reads value of
  [(number, "")] -> Just number
  _ -> Nothing

invalidArguments :: IO a
invalidArguments = do
  hPutStrLn stderr usage
  exitFailure

usage :: String
usage = unlines
  [ "Utilizare:"
  , "  cabal run dilema-crawler           Listează articolele și permite alegerea unui preview"
  , "  cabal run dilema-crawler -- --list Listează articolele"
  , "  cabal run dilema-crawler -- --preview N  Afișează preview-ul articolului N"
  , "  cabal run dilema-crawler -- --open N  Deschide articolul N în browser"
  , "  cabal run dilema-crawler -- --help"
  ]
