{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Loom.Cli.Sass (
    Sass (..)
  , SassIncludes (..)
  , findSassOnPath
  , buildSass

  , SassError (..)
  , renderSassError
  ) where

import qualified Data.Text as T
import qualified Data.Text.Lazy as Lazy

import           Loom.Cli.Build
import           Loom.Cli.Env
import           Loom.Cli.File
import           Loom.Cli.Process

import           P

import           System.IO (IO)

import qualified Text.Megaparsec as Mega
import           Text.Megaparsec.Text (Parser)

import           X.Control.Monad.Trans.Either (EitherT, left)


newtype Sass =
  Sass {
      sassPath :: FilePath
    }

data SassIncludes =
  SassIncludes {
      sassMain :: FilePath
    , sassIncludes :: [FilePath]
    } deriving (Eq, Ord, Show)

data SassError =
    SassProcessError ProcessError
  | SassFileNotFound FilePath
    deriving (Show)

renderSassError :: SassError -> Text
renderSassError = \case
  SassProcessError err ->
    renderProcessError err
  SassFileNotFound path ->
    "File not found: " <> path

findSassOnPath :: IO (Maybe Sass)
findSassOnPath =
  fmap Sass <$> verifyExecutable "sassc"

buildSass :: Sass -> SassIncludes -> FilePath -> EitherT SassError IO (Maybe FilePath)
buildSass sass (SassIncludes main includes) dist =
  doesFileExist main >>= \x -> case x of
    False ->
      pure Nothing
    True -> fmap Just $ do
      writeToFile "tmp/main.scss" $ \scss -> do
      writeToFile (dist <> "/main.css") $ \css -> do
        -- FIX Check if modified
        -- findFiles $ ["scss/**/*.scss"] <> modules ["scss"]

        writeUtf8 scss . Lazy.toStrict =<< expand includes main

        firstT SassProcessError . call (sassPath sass) . mconcat $ [
            ["-t", "compressed"]
          , [scss, css]
          ]

        -- FIX Autoprefix "last 2 version" "ie 10"
        -- https://github.com/postcss/autoprefixer
        -- FIX replaceAssetUrls
        -- FIX Source maps
        pure css

-- Sass doesn't support glob imports.
--
-- https://github.com/sass/sassc/issues/62
-- https://github.com/britco/node-sass-globbing
expand :: [FilePath] -> FilePath -> EitherT SassError IO Lazy.Text
expand includes path = do
  msass <- readUtf8 path
  case msass of
    Nothing ->
      left $ SassFileNotFound path
    Just sass ->
      fmap Lazy.unlines $ traverse (expandLine includes path) $ T.lines sass

expandLine :: [FilePath] -> FilePath -> Text -> EitherT SassError IO Lazy.Text
expandLine includes path txt =
  case Mega.runParser pImport (T.unpack path) txt of
    Left _ ->
      pure $ Lazy.fromStrict txt
    Right glob -> do
      xs <- fmap mconcat $ traverse (flip findFilesIn [glob]) includes
      fmap Lazy.unlines $ traverse (expand includes) xs

pImport :: Parser FilePath
pImport =
  let
    pre =
      Mega.string "@import" *> Mega.space *> Mega.char '"'

    post =
      Mega.char '"' <* Mega.space <* Mega.char ';'
  in
    T.pack <$> (pre *> many (Mega.noneOf ['"']) <* post)
