
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
  , edhMakeCall
  , edhMakeCall'
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
  , OriginalValue(..)
  , EdhProc
  , EdhProgState(..)
  , EdhTask(..)
  , Context(..)
  , Scope(..)
  , EdhProcedure
  , EdhProcExit
    -- ** Edh Runtime error
  , getEdhCallContext
  , edhThrow
  , edhCatch
  , throwEdh
  , edhThrowSTM
  , edhCatchSTM
  , throwEdhSTM
  , createEdhError
  , toEdhError
  , toEdhError'
  , fromEdhError
  , getEdhErrClass
    -- ** CPS helpers
  , runEdhProc
  , contEdhSTM
  , exitEdhSTM
  , exitEdhSTM'
  , exitEdhProc
  , exitEdhProc'
  , seqcontSTM
  , foldl'contSTM
  , mapcontSTM
    -- ** Sync utilities
  , forkEdh
  , edhPerformSTM
  , edhPerformIO
  , edhForkIO
  , edhNop
  , edhEndOfProc
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
  , objStore
  , castObjectStore
  , castObjectStore'
  , Class
  , EdhHostCtor
  , mkHostClass
  , mkExtHostClass
  , mkHostProperty
  , Entity(..)
  , EntityManipulater(..)
  , lookupEntityAttr
  , allEntityAttrs
  , changeEntityAttr
  , updateEntityAttrs
  , createMaoEntity
  , maoEntityManipulater
  , createHashEntity
  , hashEntityManipulater
  , createSideEntityManipulater
  , createSideEntity
  , withThatEntity
  , withThatEntity'
  , withEntityOfClass
  , withEntityOfClass'
  , modifyThatEntity
  , modifyThatEntity'
  , modifyEntityOfClass
  , modifyEntityOfClass'
  , viewAsEdhObject
  , cloneEdhObject
  , createEdhObject
  , constructEdhObject
  , AttrKey(..)
  , attrKeyValue
  , lookupEdhCtxAttr
  , resolveEdhCtxAttr
  , lookupEdhObjAttr
  , lookupEdhSuperAttr
  , resolveEdhInstance
  , objectScope
  , mkScopeWrapper
  , isScopeWrapper
  , wrappedScopeOf

    -- ** Value system
  , createEdhDict
  , edhTypeNameOf
  , edhTypeOf
  , edhValueNull
  , edhIdentEqual
  , edhNamelyEqual
  , edhValueEqual
  , edhValueRepr
  , edhValueReprSTM
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
import           Language.Edh.Runtime
import           Language.Edh.Event
import           Language.Edh.Details.IOPD
import           Language.Edh.Details.RtTypes
import           Language.Edh.Details.CoreLang
import           Language.Edh.Details.Evaluate
import           Language.Edh.Details.Utils

