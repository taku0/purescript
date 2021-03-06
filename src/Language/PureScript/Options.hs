-----------------------------------------------------------------------------
--
-- Module      :  Language.PureScript.Options
-- Copyright   :  (c) Phil Freeman 2013
-- License     :  MIT
--
-- Maintainer  :  Phil Freeman <paf31@cantab.net>
-- Stability   :  experimental
-- Portability :
--
-- |
-- The data type of compiler options
--
-----------------------------------------------------------------------------

module Language.PureScript.Options where

-- |
-- The data type of compiler options
--
data Options = Options {
    -- |
    -- Perform tail-call elimination
    --
    optionsTco :: Bool
    -- |
    -- Perform type checks at runtime
    --
  , optionsPerformRuntimeTypeChecks :: Bool
    -- |
    -- Inline calls to ret and bind for the Eff monad
    --
  , optionsMagicDo :: Bool
    -- |
    -- Check the type of Main.main and generate its code
    --
  , optionsRunMain :: Bool
  } deriving Show

-- |
-- Default compiler options
--
defaultOptions :: Options
defaultOptions = Options False False False False
