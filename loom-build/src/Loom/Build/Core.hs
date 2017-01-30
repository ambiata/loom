{-# LANGUAGE NoImplicitPrelude #-}
module Loom.Build.Core (
    LoomError (..)
  , buildLoom
  ) where

import           Loom.Build.Data

import           P

import           System.IO (IO)

import           X.Control.Monad.Trans.Either (EitherT)

data LoomError =
    LoomError
  deriving (Eq, Show)

buildLoom :: Loom -> EitherT LoomError IO ()
buildLoom _ =
  pure ()
