
module Language.Edh.Control where

import           Prelude

import           Control.Exception
import           Control.Monad.State.Strict

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


data EdhCallFrame = EdhCallFrame {
      edhCalleeProcName :: !Text
    , edhCalleeDefiLoca :: !Text
    , edhCallerFromLoca :: !Text
  } deriving (Eq, Typeable)
instance Show EdhCallFrame where
  show = T.unpack . dispEdhCallFrame
dispEdhCallFrame :: EdhCallFrame -> Text
dispEdhCallFrame (EdhCallFrame !pname !pdefi !pcaller) =
  "📜 " <> pname <> " 🔎 " <> pdefi <> " 👈 " <> pcaller

data EdhCallContext = EdhCallContext {
      edhCallTipLoca :: !Text
    , edhCallFrames :: ![EdhCallFrame]
  } deriving (Eq, Typeable)
instance Show EdhCallContext where
  show = T.unpack . dispEdhCallContext
dispEdhCallContext :: EdhCallContext -> Text
dispEdhCallContext (EdhCallContext !tip !frames) =
  T.unlines $ (dispEdhCallFrame <$> frames) ++ ["👉 " <> tip]


data EvalError = EvalError !Text !EdhCallContext
  deriving (Eq, Typeable)
instance Show EvalError where
  show (EvalError msg _) = T.unpack msg
instance Exception EvalError


newtype UsageError = UsageError Text
  deriving (Eq, Typeable, Show)
instance Exception UsageError


data EdhError = EdhParseError ParserError | EdhEvalError EvalError | EdhUsageError UsageError
    deriving (Eq, Typeable)
instance Show EdhError where
  show (EdhParseError !err) = "⛔ " ++ errorBundlePretty err
  show (EdhEvalError (EvalError !msg !ctx)) =
    "💔\n" <> show ctx <> "💣 " <> T.unpack msg
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
