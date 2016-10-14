{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Loom.Cli.Asset (
    AssetManifest (..)
  , buildAssets
  ) where

import           Loom.Cli.Build
import           Loom.Cli.File

import           P

import           System.IO (IO)


data AssetManifest =
  AssetManifest [HashedFile]

assetExtensions :: [Text]
assetExtensions =
  [
      "png", "jpg", "gif", "svg", "ico"
    , "woff", "otf", "ttf", "eot"
    ]

buildAssets :: IO AssetManifest
buildAssets = do
  -- FIX Write to "tmp/assets-main-manifest.json" here?
  assets <- findFiles $ modules assetExtensions
  -- FIX Still need to work out when to copy vs hash?
  assetsHashed <- hashFiles "FIX" "tmp/assets" assets
  pure $ AssetManifest assetsHashed
