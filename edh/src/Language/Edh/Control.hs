
module Language.Edh.Control where

import           Prelude

import           Control.Exception
import           Control.Monad.State.Strict

import           Data.Foldable
import           Data.Void
import           Data.Typeable
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import qualified Data.HashMap.Strict           as Map

import           Text.Megaparsec         hiding ( State )


type OpSymbol = Text
type Precedence = Int

-- use such a dict as the parsing state, to implement
-- object-language-declarable operator precendence
type OpPrecDict = Map.HashMap OpSymbol (Precedence, Text)

-- no backtracking needed for precedence dict, so it
-- can live in the inner monad of 'ParsecT'.
type Parser = ParsecT Void Text (State OpPrecDict)

-- so goes this simplified parsing err type name
type ParserError = ParseErrorBundle Text Void


type ProcedureName = Text
type ProcedureDefineLoc = Text
type ProcedureCallerLoc = Text

data EdhErrorContext = EdhErrorContext {
    edhErrorMsg :: !Text
    , edhErrorLocation :: !Text
    , edhErrorStack :: ![(
        ProcedureName,
        ProcedureDefineLoc,
        ProcedureCallerLoc
        )]
  } deriving (Eq, Typeable)

newtype EvalError = EvalError EdhErrorContext
  deriving (Eq, Typeable)
instance Show EvalError where
  show (EvalError (EdhErrorContext msg _ _)) = T.unpack msg
instance Exception EvalError


newtype UsageError = UsageError Text
  deriving (Eq, Typeable, Show)
instance Exception UsageError


data EdhError = EdhParseError ParserError | EdhEvalError EvalError | EdhUsageError UsageError
    deriving (Eq, Typeable)
instance Show EdhError where
  show (EdhParseError err) = "⛔ " ++ errorBundlePretty err
  show (EdhEvalError (EvalError (EdhErrorContext msg loc stack))) =
    T.unpack $ backtrace <> "\n💣 " <> msg <> "\n👉 " <> loc
   where
    backtrace = foldl'
      (\st (pname, pdef, pcaller) ->
        st <> "\n📜 " <> pname <> " 🔎 " <> pdef <> " 👈 " <> pcaller
      )
      ("💔" :: Text)
      stack
  show (EdhUsageError (UsageError msg)) = "🐒 " ++ T.unpack msg
instance Exception EdhError


edhKnownError :: SomeException -> Maybe EdhError
edhKnownError err = case fromException err :: Maybe EdhError of
  Just e  -> Just e
  Nothing -> case fromException err :: Maybe EvalError of
    Just e  -> Just $ EdhEvalError e
    Nothing -> case fromException err :: Maybe ParserError of
      Just e  -> Just $ EdhParseError e
      Nothing -> case fromException err :: Maybe UsageError of
        Just e  -> Just $ EdhUsageError e
        Nothing -> Nothing
