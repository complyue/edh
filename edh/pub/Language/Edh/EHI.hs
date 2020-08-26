
-- | Edh Host Interface
--
-- With Haskell as the host language, Edh as the surface language,
-- this defines the interface for host code in Haskell to create
-- & control embedded Edh worlds, and to splice host (typically
-- side-effects free, i.e. pure, and fast-in-machine-speed)
-- functions, wrapped as host procedures, with procedures written
-- in Edh, those do arbitrary manipulations on arbitrary objects
-- in the world, but, less speedy as with interpreted execution.
module Language.Edh.EHI
  (
    -- * Exceptions
    EdhError(..)
  , EdhErrorTag(..)
  , ParserError
  , EdhCallFrame(..)
  , EdhCallContext(..)
  , edhKnownError

    -- * Event processing
  , EventSink(..)
  , newEventSink
  , subscribeEvents
  , publishEvent
  , forkEventProducer
  , forkEventConsumer
  , waitEventConsumer

    -- * STM/IO API for spliced interpreter

    -- ** Console interface w/ a default implementation
  , EdhConsole(..)
  , EdhConsoleIO(..)
  , EdhLogger
  , LogLevel
  , defaultEdhConsole
  , defaultEdhConsoleSettings

    -- ** World bootstraping
  , EdhWorld(..)
  , createEdhWorld
  , worldContext
  , installEdhBatteries
  , declareEdhOperators

    -- ** Spliced execution
  , performEdhEffect
  , performEdhEffect'
  , behaveEdhEffect
  , behaveEdhEffect'
  , runEdhModule
  , runEdhModule'
  , EdhModulePreparation
  , edhModuleAsIs
  , createEdhModule
  , installEdhModule
  , installedEdhModule
  , importEdhModule
  , moduleContext
  , contextScope
  , contextFrame
  , parseEdh
  , parseEdh'
  , evalEdh
  , evalEdh'
  , haltEdhProgram
  , runEdhProgram
  , runEdhProgram'
  , edhPrepareCall
  , edhPrepareCall'
  , callEdhMethod
  , evalStmt
  , evalStmt'
  , evalBlock
  , evalCaseBlock
  , evalExpr
  , evalExprs
  , recvEdhArgs
  , packEdhExprs
  , packEdhArgs
  , EdhTx
  , EdhThreadState(..)
  , EdhTask(..)
  , Context(..)
  , Scope(..)
  , EdhHostProc
  , EdhTxExit
    -- ** Edh Runtime error
  , getEdhCallContext
  , edhThrow
  , edhCatch
  , throwEdh
  , edhThrowTx
  , edhCatchTx
  , throwEdhTx
    -- ** CPS helpers
  , exitEdh
  , runEdhTx
  , exitEdhTx
  , seqcontSTM
  , foldl'contSTM
  , mapcontSTM
    -- ** Sync utilities
  , forkEdh
  , edhContSTM
  , edhContIO
  , endOfEdh
    -- ** Reflective manipulation
  , StmtSrc(..)
  , Stmt(..)
  , Expr(..)
  , Prefix(..)
  , Literal(..)
  , AttrName
  , AttrAddr(..)
  , AttrAddressor(..)
  , ArgsReceiver(..)
  , ArgReceiver(..)
  , mandatoryArg
  , optionalArg
  , ArgsPacker
  , ArgSender(..)
  , ProcDecl(..)
  , procedureName
  , SourcePos(..)
  , mkPos
  , sourcePosPretty
  , deParen

    -- ** Object system
  , Object(..)
  , castObjectStore
  , castObjectStore'
  , Class
  , mkHostClass
  , mkHostClass'
  , mkHostProperty
  , edhCreateObj
  , edhConstructObj
  , edhMutCloneObj
  , AttrKey(..)
  , attrKeyValue
  , lookupEdhCtxAttr
  , resolveEdhCtxAttr
  , lookupEdhObjAttr
  , lookupEdhSuperAttr
  , resolveEdhInstance
  , objectScope
  , mkScopeWrapper

    -- ** Value system
  , createEdhDict
  , edhTypeNameOf
  , edhTypeOf
  , edhValueNull
  , edhIdentEqual
  , edhNamelyEqual
  , edhValueEqual
  , edhValueRepr
  , edhValueReprTx
  , edhValueStr
  , edhValueStrTx
  , EdhValue(..)
  , EdhTypeValue(..)
  , edhDeCaseClose
  , edhUltimate
  , nil
  , edhNone
  , edhNoneExpr
  , edhNothing
  , edhNothingExpr
  , noneNil
  , true
  , false
  , nan
  , inf
  , D.Decimal(..)
  , Symbol(..)
  , symbolName
  , Dict(..)
  , ItemKey
  , setDictItem
  , List(..)
  , ArgsPack(..)
  , ProcDefi(..)
  , EdhGenrCaller
  , globalSymbol
  , mkSymbol
  , mkUUID
  , mkHostProc
  , mkSymbolicHostProc
  , mkIntrinsicOp
  , EdhVector

    -- * args pack parsing
  , ArgsPackParser(..)
  , parseArgsPack

    -- * indexing and slicing support
  , EdhIndex(..)
  , parseEdhIndex
  , edhRegulateSlice
  , edhRegulateIndex

    -- * standalone modules
  , module Language.Edh.Details.IOPD
  )
where

import           Text.Megaparsec

import qualified Data.Lossless.Decimal         as D

import           Language.Edh.Control
import           Language.Edh.Batteries
import           Language.Edh.Batteries.Vector
import           Language.Edh.Runtime
import           Language.Edh.Event
import           Language.Edh.Details.IOPD
import           Language.Edh.Details.RtTypes
import           Language.Edh.Details.CoreLang
import           Language.Edh.Details.Evaluate
import           Language.Edh.Details.Utils

