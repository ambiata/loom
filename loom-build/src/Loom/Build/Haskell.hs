{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Loom.Build.Haskell (
    LoomHaskellError (..)
  , generateHaskell
  , generateAssetHaskell
  , generateCabal
  , renderLoomHaskellError
  ) where

import           Control.Monad.Catch (handleIf)
import           Control.Monad.IO.Class (liftIO)

import qualified Data.Char as Char
import qualified Data.Text as T
import qualified Data.Text.IO as T

import           Loom.Build.Assets
import           Loom.Build.Data
import           Loom.Core.Data
import           Loom.Projector (ProjectorHaskellError, ProjectorOutput)
import qualified Loom.Projector as Projector

import           P

import           System.Directory (canonicalizePath, createDirectoryIfMissing)
import           System.FilePath ((</>), FilePath, dropExtension, joinPath, takeDirectory, takeFileName)
import           System.IO (IO)
import qualified System.IO.Error as IO.Error
import qualified System.Posix.Files as Unix

import           X.Control.Monad.Trans.Either (EitherT)

data LoomHaskellError =
    LoomHaskellProjectorError ProjectorHaskellError
  deriving (Show)

-- FIX The use of css/js in this module is stringy, we shouldn't be manipulating file paths

generateHaskell :: FilePath -> LoomSitePrefix -> AssetsPrefix -> LoomResult -> EitherT LoomHaskellError IO ()
generateHaskell output spx apx (LoomResult name _ _mo po inputCss images inputJs) = do
  let
    outputCss = CssFile $ cssFileOutput inputCss
    outputJs' = fmap (fmap (JsFile . jsFileOutput)) inputJs
    outputJs = fmap snd outputJs'
  liftIO $
    createDirectoryIfMissing True output
  void . firstT LoomHaskellProjectorError $
    Projector.generateProjectorHaskell (output </> "src") spx apx [outputCss] images outputJs' po
  liftIO $
    prefixCssImageAssets spx apx images (CssFile . (</>) output . cssAssetFilePath apx $ outputCss) inputCss
  liftIO $
    createAssetSymlinks output apx images (fmap snd inputJs)
  liftIO $
    generateAssetHaskell name output spx apx outputCss images outputJs
  liftIO $
    generateCabal name output po apx outputCss images outputJs

generateAssetHaskell ::
     LoomName
  -> FilePath
  -> LoomSitePrefix
  -> AssetsPrefix
  -> CssFile
  -> [ImageFile]
  -> [JsFile]
  -> IO ()
generateAssetHaskell name output spx apx css images js = do
  let
    f = output </> "src" </> assetModulePath name
    q p t = "(\"" <> p <> "\", $(embedFile \"" <> T.pack t <> "\"))"
    q2 p t = "(\"" <> p <> "\", \"" <> T.pack (output </> t) <> "\")"
    images' = with images $ \i -> (,) (imageAssetPath spx apx i) (imageAssetFilePath apx i)
    css' = (,) (cssAssetPath spx apx css) (cssAssetFilePath apx css)
    js' = with js $ \j -> (,) (jsAssetPath spx apx j) (jsAssetFilePath apx j)
  createDirectoryIfMissing True . takeDirectory $ f
  T.writeFile f $
    T.unlines [
        "{-# LANGUAGE CPP #-}"
      , "{-# LANGUAGE NoImplicitPrelude #-}"
      , "{-# LANGUAGE OverloadedStrings #-}"
      , "{-# LANGUAGE TemplateHaskell #-}"
      , "module " <> renderAssetModuleName name <> " where"
      , ""
      , "import           Data.Monoid ((<>))"
      , "import           Data.Text (Text)"
      , ""
      , "import           Loom.Runtime.Wai"
      , ""
      , "#if CABAL"
      , "cssAssets :: Assets"
      , "cssAssets ="
      , "  fromList [" <> uncurry q css' <> "]"
      , "#else"
      , "cssAssets :: AssetsDev"
      , "cssAssets ="
      , "  fromListDev [" <> uncurry q2 css' <> "]"
      , "#endif"
      , ""
      , "css :: [Text]"
      , "css ="
      , "  assetPaths cssAssets"
      , ""
      , "#if CABAL"
      , "jsAssets :: Assets"
      , "jsAssets ="
      , "  fromList [  " <> (T.intercalate "\n    , " . fmap (uncurry q)) js'
      , "    ]"
      , "#else"
      , "jsAssets :: AssetsDev"
      , "jsAssets ="
      , "  fromListDev [  " <> (T.intercalate "\n    , " . fmap (uncurry q2)) js'
      , "    ]"
      , "#endif"
      , ""
      , "#if CABAL"
      , "imagesAssets :: Assets"
      , "imagesAssets ="
      , "  fromList [  " <> (T.intercalate "\n    , " . fmap (uncurry q)) images'
      , "    ]"
      , "#else"
      , "imagesAssets :: AssetsDev"
      , "imagesAssets ="
      , "  fromListDev [  " <> (T.intercalate "\n    , " . fmap (uncurry q2)) images'
      , "    ]"
      , "#endif"
      , ""
      , "assetMiddleware :: Middleware"
      , "assetMiddleware ="
      , "#if CABAL"
      , "  assetsMiddleware"
      , "#else"
      , "  assetsMiddlewareDev"
      , "#endif"
      , "    (cssAssets <> jsAssets <> imagesAssets)"
      ]

createAssetSymlinks :: FilePath -> AssetsPrefix ->  [ImageFile] -> [JsFile] -> IO ()
createAssetSymlinks output apx images js = do
  let
    link i o = do
      createDirectoryIfMissing True . takeDirectory $ o
      ic <- canonicalizePath i
      handleIf IO.Error.isAlreadyExistsError (pure . const ()) $
        Unix.createSymbolicLink ic o
  for_ images $ \i ->
    link (imageFilePath i) (output </> imageAssetFilePath apx i)
  for_ js $ \j ->
    link (renderJsFile j) (output </> (jsAssetFilePath apx . JsFile . jsFileOutput) j)

generateCabal ::
  LoomName ->
  FilePath ->
  ProjectorOutput ->
  AssetsPrefix ->
  CssFile ->
  [ImageFile] ->
  [JsFile] ->
  IO ()
generateCabal name output po apx css images js = do
  let
    n = (T.map (\c -> if Char.isAlphaNum c then Char.toLower c else '-') . renderLoomName) name <> "-loom"
    sourceFiles =
      cssAssetFilePath apx css : fmap (imageAssetFilePath apx) images <> fmap (jsAssetFilePath apx) js
  T.writeFile (output </> T.unpack n <> ".cabal") $
    T.unlines [
        "name:          " <> n
      , "version:       0.0.1"
      , "license:       AllRightsReserved"
      , "author:        Loom"
      , "maintainer:    Loom"
      , "synopsis:      synopsis"
      , "category:      Development"
      , "cabal-version: >= 1.8"
      , "build-type:    Simple"
      , "description:   description"
      , ""
      , "extra-source-files:"
      , "    " <> (T.intercalate "\n  , " . fmap T.pack) sourceFiles
      , ""
      , "library"
      , "  hs-source-dirs: src"
      , "  build-depends:"
      , "      base                        >= 3          && < 5"
      , "    , transformers                >= 0.4        && < 6"
      , "    , text                        >= 1.1        && < 1.3"
      , "    , ambiata-loom-runtime"
      , "    , ambiata-projector-html-runtime"
      , ""
      , "  ghc-options: -Wall -O2"
      , "  cpp-options: -DCABAL=1"
      , ""
      , "  exposed-modules:"
      , T.unlines . fmap ((<>) "    ") . mconcat $ [
            [renderAssetModuleName name]
          , fmap Projector.unModuleName . Projector.projectorOutputModules $ po
          ]
      ]

assetModulePath :: LoomName -> FilePath
assetModulePath  =
  flip (<>) ".hs" . joinPath . fmap T.unpack . T.splitOn "." . renderAssetModuleName

renderAssetModuleName :: LoomName -> Text
renderAssetModuleName n =
  (filePathToModuleName . T.unpack . renderLoomName) n <> ".Assets"

cssFileOutput :: CssFile -> FilePath
cssFileOutput =
  takeFileName . renderCssFile

jsFileOutput :: JsFile -> FilePath
jsFileOutput =
  takeFileName . renderJsFile

filePathToModuleName :: FilePath -> Text
filePathToModuleName =
  T.pack . goUpper . dropExtension
  where
    goUpper [] = []
    goUpper (x:xs)
      | Char.isAlphaNum x = Char.toUpper x : go xs
      | otherwise = goUpper xs
    go [] = []
    go (x:xs)
      | x == '/' = '.' : goUpper xs
      | Char.isAlphaNum x = x : go xs
      | otherwise = goUpper xs

renderLoomHaskellError :: LoomHaskellError -> Text
renderLoomHaskellError he =
  case he of
    LoomHaskellProjectorError e ->
      Projector.renderProjectorHaskellError e
