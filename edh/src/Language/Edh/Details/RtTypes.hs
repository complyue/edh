
module Language.Edh.Details.RtTypes where

import           Prelude
-- import           Debug.Trace

import           GHC.Conc                       ( unsafeIOToSTM )
import           System.IO.Unsafe

import           Control.Monad.Except
import           Control.Monad.Reader

-- import           Control.Concurrent
import           Control.Concurrent.STM

import           Data.Maybe
import           Data.Foldable
import           Data.Unique
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import           Data.Hashable
import qualified Data.HashMap.Strict           as Map
import           Data.List.NonEmpty             ( NonEmpty(..) )
import qualified Data.List.NonEmpty            as NE
import           Data.Dynamic

import           Text.Megaparsec

import           Data.Lossless.Decimal         as D

import           Language.Edh.Control


-- | A dict in Edh is neither an object nor an entity, but just a
-- mutable associative array.
data Dict = Dict !Unique !(TVar DictStore)
instance Eq Dict where
  Dict x'u _ == Dict y'u _ = x'u == y'u
instance Ord Dict where
  compare (Dict x'u _) (Dict y'u _) = compare x'u y'u
instance Hashable Dict where
  hashWithSalt s (Dict u _) = hashWithSalt s u
instance Show Dict where
  show (Dict _ d) = showEdhDict ds where ds = unsafePerformIO $ readTVarIO d
type ItemKey = EdhValue
type DictStore = Map.HashMap EdhValue EdhValue

showEdhDict :: DictStore -> String
showEdhDict ds = if Map.null ds
  then "{}" -- no space should show in an empty dict
  else -- advocate trailing comma here
    "{ "
    ++ concat [ show k ++ ":" ++ show v ++ ", " | (k, v) <- Map.toList ds ]
    ++ "}"

-- | setting to `nil` value means deleting the item by the specified key
setDictItem :: ItemKey -> EdhValue -> DictStore -> DictStore
setDictItem !k v !ds = case v of
  EdhNil -> Map.delete k ds
  _      -> Map.insert k v ds

dictEntryList :: DictStore -> [EdhValue]
dictEntryList d = (<$> Map.toList d) $ \(k, v) -> EdhTuple [k, v]

edhDictFromEntity :: EdhProgState -> Entity -> STM Dict
edhDictFromEntity pgs ent = do
  u  <- unsafeIOToSTM newUnique
  ps <- allEntityAttrs pgs ent
  (Dict u <$>) $ newTVar $ Map.fromList [ (attrKeyValue k, v) | (k, v) <- ps ]

-- | An entity in Edh is the backing storage for a scope, with possibly 
-- an object (actually more objects still possible, but god forbid it)
-- mounted to it with one class and many supers.
--
-- An entity has attributes associated by 'AttrKey'.
data Entity = Entity {
    entity'ident :: !Unique
    , entity'store :: !(TVar Dynamic)
    , entity'man :: !EntityManipulater
  }
instance Eq Entity where
  Entity x'u _ _ == Entity y'u _ _ = x'u == y'u
instance Ord Entity where
  compare (Entity x'u _ _) (Entity y'u _ _) = compare x'u y'u
instance Hashable Entity where
  hashWithSalt s (Entity u _ _) = hashWithSalt s u

-- | Backing storage manipulation interface for entities
--
-- Arbitrary resources (esp. statically typed artifacts bearing high machine
-- performance purpose) can be wrapped as virtual entities through this interface.
data EntityManipulater = EntityManipulater {
    -- a result of `EdhNil` (i.e. `nil`) means no such attr, should usually lead
    -- to error;
    -- while an `EdhExpr _ (LitExpr NilLiteral) _` (i.e. `None` or `Nothing`)
    -- means knowingly absent, usually be okay and handled via pattern matching
    -- or equality test.
    lookup'entity'attr :: !(EdhProgState -> AttrKey -> Dynamic -> STM EdhValue)

    -- enumeration of attrs (this better be lazy)
    , all'entity'attrs :: !(EdhProgState -> Dynamic -> STM [(AttrKey, EdhValue)])

    -- single attr change
    , change'entity'attr :: !(EdhProgState -> AttrKey -> EdhValue -> Dynamic ->  STM Dynamic)

    -- bulk attr change
    , update'entity'attrs :: !(EdhProgState -> [(AttrKey, EdhValue)] -> Dynamic -> STM Dynamic)
  }

lookupEntityAttr :: EdhProgState -> Entity -> AttrKey -> STM EdhValue
lookupEntityAttr pgs (Entity _ !es !em) !k = do
  esd <- readTVar es
  lookup'entity'attr em pgs k esd
{-# INLINE lookupEntityAttr #-}

allEntityAttrs :: EdhProgState -> Entity -> STM [(AttrKey, EdhValue)]
allEntityAttrs pgs (Entity _ !es !em) = do
  esd <- readTVar es
  all'entity'attrs em pgs esd
{-# INLINE allEntityAttrs #-}

changeEntityAttr :: EdhProgState -> Entity -> AttrKey -> EdhValue -> STM ()
changeEntityAttr pgs (Entity _ !es !em) !k !v = do
  esd  <- readTVar es
  esd' <- change'entity'attr em pgs k v esd
  writeTVar es esd'
{-# INLINE changeEntityAttr #-}

updateEntityAttrs :: EdhProgState -> Entity -> [(AttrKey, EdhValue)] -> STM ()
updateEntityAttrs pgs (Entity _ !es !em) !ps = do
  esd  <- readTVar es
  esd' <- update'entity'attrs em pgs ps esd
  writeTVar es esd'
{-# INLINE updateEntityAttrs #-}

data AttrKey = AttrByName !AttrName | AttrBySym !Symbol
    deriving (Eq, Ord)
instance Show AttrKey where
  show (AttrByName attrName      ) = T.unpack attrName
  show (AttrBySym  (Symbol _ sym)) = "@" <> T.unpack sym
instance Hashable AttrKey where
  hashWithSalt s (AttrByName name) =
    s `hashWithSalt` (0 :: Int) `hashWithSalt` name
  hashWithSalt s (AttrBySym sym) =
    s `hashWithSalt` (1 :: Int) `hashWithSalt` sym

type AttrName = Text

attrKeyValue :: AttrKey -> EdhValue
attrKeyValue (AttrByName nm ) = EdhString nm
attrKeyValue (AttrBySym  sym) = EdhSymbol sym


-- | Create a constantly empty entity - 冇
createMaoEntity :: STM Entity
createMaoEntity = do
  u  <- unsafeIOToSTM newUnique
  es <- newTVar $ toDyn EdhNil
  return $ Entity u es $ EntityManipulater the'lookup'entity'attr
                                           the'all'entity'attrs
                                           the'change'entity'attr
                                           the'update'entity'attrs
 where
  the'lookup'entity'attr _ _ _ = return EdhNil
  the'all'entity'attrs _ _ = return []
  the'change'entity'attr _ _ _ = return  -- TODO raise error instead ?
  the'update'entity'attrs _ _ = return  -- TODO raise error instead ?


-- | Create an entity with an in-band 'Data.HashMap.Strict.HashMap'
-- as backing storage
createHashEntity :: Map.HashMap AttrKey EdhValue -> STM Entity
createHashEntity !m = do
  u  <- unsafeIOToSTM newUnique
  es <- newTVar $ toDyn m
  return $ Entity u es $ EntityManipulater the'lookup'entity'attr
                                           the'all'entity'attrs
                                           the'change'entity'attr
                                           the'update'entity'attrs
 where
  hm = flip fromDyn Map.empty
  the'lookup'entity'attr _ !k = return . fromMaybe EdhNil . Map.lookup k . hm
  the'all'entity'attrs _ = return . Map.toList . hm
  the'change'entity'attr _ !k !v !d =
    let !ds = fromDyn d Map.empty
    in  return $ toDyn $ case v of
          EdhNil -> Map.delete k ds
          _      -> Map.insert k v ds
  the'update'entity'attrs _ !ps =
    return . toDyn . Map.union (Map.fromList ps) . hm


-- | Create an entity with an out-of-band 'Data.HashMap.Strict.HashMap'
-- as backing storage
createSideEntity :: Bool -> STM (Entity, TVar (Map.HashMap AttrKey EdhValue))
createSideEntity !writeProtected = do
  obs <- newTVar Map.empty
  let the'lookup'entity'attr _ !k _ =
        fromMaybe EdhNil . Map.lookup k <$> readTVar obs
      the'all'entity'attrs _ _ = Map.toList <$> readTVar obs
      the'change'entity'attr pgs !k !v inband = if writeProtected
        then
          throwSTM -- make this catchable from Edh code ?
          $ EdhError EvalError "Writing a protected entity"
          $ getEdhCallContext 0 pgs
        else do
          modifyTVar' obs $ Map.insert k v
          return inband
      the'update'entity'attrs pgs !ps inband = if writeProtected
        then
          throwSTM -- make this catchable from Edh code ?
          $ EdhError EvalError "Writing a protected entity"
          $ getEdhCallContext 0 pgs
        else do
          modifyTVar' obs $ Map.union (Map.fromList ps)
          return inband
  u  <- unsafeIOToSTM newUnique
  es <- newTVar $ toDyn nil -- put a nil in-band atm
  return
    ( Entity u es $ EntityManipulater the'lookup'entity'attr
                                      the'all'entity'attrs
                                      the'change'entity'attr
                                      the'update'entity'attrs
    , obs
    )


-- | A symbol can stand in place of an alphanumeric name, used to
-- address an attribute from an object entity, but symbols are 
-- private to its owning scope, can not be imported from out side
-- of the scope, thus serves encapsulation purpose in object
-- structure designs.
--
-- And symbol values reside in a lexical outer scope are available
-- to its lexical inner scopes, e.g. a symbol bound to a module is
-- available to all procedures defined in the module, and a symbol
-- bound within a class procedure is available to all its methods
-- as well as nested classes.
data Symbol = Symbol !Unique !Text
instance Eq Symbol where
  Symbol x'u _ == Symbol y'u _ = x'u == y'u
instance Ord Symbol where
  compare (Symbol x'u _) (Symbol y'u _) = compare x'u y'u
instance Hashable Symbol where
  hashWithSalt s (Symbol u _) = hashWithSalt s u
instance Show Symbol where
  show (Symbol _ sym) = T.unpack sym
mkSymbol :: Text -> STM Symbol
mkSymbol !description = do
  !u <- unsafeIOToSTM newUnique
  return $ Symbol u description


-- | A list in Edh is a multable, singly-linked, prepend list.
data List = List !Unique !(TVar [EdhValue])
instance Eq List where
  List x'u _ == List y'u _ = x'u == y'u
instance Ord List where
  compare (List x'u _) (List y'u _) = compare x'u y'u
instance Hashable List where
  hashWithSalt s (List u _) = hashWithSalt s u
instance Show List where
  show (List _ !l) = if null ll
    then "[]"
    else "[ " ++ concat [ show i ++ ", " | i <- ll ] ++ "]"
    where ll = unsafePerformIO $ readTVarIO l


-- | The execution context of an Edh thread
data Context = Context {
    -- | the Edh world in context
    contextWorld :: !EdhWorld
    -- | the call stack frames of Edh procedures
    , callStack :: !(NonEmpty Scope)
    -- | the direct generator caller
    , generatorCaller :: !(Maybe EdhGenrCaller)
    -- | the match target value in context, normally be `true`, or the
    -- value from `x` in a `case x of` block
    , contextMatch :: EdhValue
    -- | currently executing statement
    , contextStmt :: !StmtSrc
  }
contextScope :: Context -> Scope
contextScope = NE.head . callStack

type EdhGenrCaller
  = ( -- the caller's state
       EdhProgState
      -- the yield receiver, a.k.a. the caller's continuation
    ,  EdhValue -- one value yielded from the generator
    -> ( -- continuation of the genrator
          EdhValue -- value given to the `yield` expr in generator
       -> STM ()
       )
    -> EdhProc
    )


-- | Throw from an Edh proc, be cautious NOT to have any monadic action
-- following such a throw, or it'll silently fail to work out.
edhThrow :: EdhValue -> (EdhValue -> EdhProc) -> EdhProc
edhThrow !exv uncaught = do
  pgs <- ask
  let propagateExc :: EdhValue -> [Scope] -> EdhProc
      propagateExc exv' [] = uncaught exv'
      propagateExc exv' (frame : stack) =
        exceptionHandler frame exv' $ \exv'' -> propagateExc exv'' stack
  propagateExc exv $ NE.toList $ callStack $ edh'context pgs

defaultEdhExceptionHandler :: EdhExcptHndlr
defaultEdhExceptionHandler !exv !rethrow = rethrow exv

edhErrorUncaught :: EdhValue -> EdhProc
edhErrorUncaught !exv = ask >>= \pgs -> contEdhSTM $ case exv of
  EdhObject exo -> do
    esd <- readTVar $ entity'store $ objEntity exo
    case fromDynamic esd :: Maybe EdhError of
      Just !edhErr -> -- TODO replace cc in err if is empty here ?
        throwSTM edhErr
      Nothing -> -- TODO support magic method to coerce as exception ?
        throwSTM $ EdhError EvalError (T.pack $ show exv) $ getEdhCallContext
          0
          pgs
  _ -> -- coerce arbitrary value to EdhError
    throwSTM $ EdhError EvalError (T.pack $ show exv) $ getEdhCallContext 0 pgs

type EdhExcptHndlr
  =  EdhValue -- ^ the error value to handle
  -> (EdhValue -> EdhProc) -- ^ action to re-throw if not recovered
  -> EdhProc


-- Especially note that Edh has no block scope as in C
-- family languages, JavaScript neither does before ES6,
-- Python neither does until now (2020).
--
-- There is only `procedure scope` in Edh
-- also see https://github.com/e-wrks/edh/Tour/#procedure
data Scope = Scope {
    -- | the entity of this scope, it's unique in a method procedure,
    -- and is the underlying entity of 'thisObject' in a class procedure.
    scopeEntity :: !Entity
    -- | `this` object in this scope
    , thisObject :: !Object
    -- | `that` object in this scope
    , thatObject :: !Object
    -- | the exception handler, `catch`/`finally` should capture the
    -- outer scope, and run its *tried* block with a new stack whose
    -- top frame is a scope all same but the `exceptionHandler` field,
    -- which executes its handling logics appropriately.
    , exceptionHandler :: !EdhExcptHndlr
    -- | the Edh procedure holding this scope
    , scopeProc :: !ProcDefi
    -- | the Edh stmt caused creation of this scope
    , scopeCaller :: !StmtSrc
  }
instance Eq Scope where
  x == y = scopeEntity x == scopeEntity y
instance Ord Scope where
  compare x y = compare (scopeEntity x) (scopeEntity y)
instance Hashable Scope where
  hashWithSalt s x = hashWithSalt s (scopeEntity x)
instance Show Scope where
  show (Scope _ _ _ _ (ProcDefi _ _ (ProcDecl pName _ procBody)) (StmtSrc (cPos, _)))
    = "📜 " ++ T.unpack pName ++ " 🔎 " ++ defLoc ++ " 👈 " ++ sourcePosPretty cPos
   where
    defLoc = case procBody of
      Right _                   -> "<host-code>"
      Left  (StmtSrc (dPos, _)) -> sourcePosPretty dPos

outerScopeOf :: Scope -> Maybe Scope
outerScopeOf = procedure'lexi . scopeProc

objectScope :: Context -> Object -> Scope
objectScope ctx obj = Scope { scopeEntity      = objEntity obj
                            , thisObject       = obj
                            , thatObject       = obj
                            , scopeProc        = objClass obj
                            , scopeCaller      = contextStmt ctx
                            , exceptionHandler = defaultEdhExceptionHandler
                            }

-- | An object views an entity, with inheritance relationship 
-- to any number of super objects.
data Object = Object {
    -- | the entity stores attribute set of the object
      objEntity :: !Entity
    -- | the class (a.k.a constructor) procedure of the object
    , objClass :: !ProcDefi
    -- | up-links for object inheritance hierarchy
    , objSupers :: !(TVar [Object])
  }
instance Eq Object where
  Object x'u _ _ == Object y'u _ _ = x'u == y'u
instance Ord Object where
  compare (Object x'u _ _) (Object y'u _ _) = compare x'u y'u
instance Hashable Object where
  hashWithSalt s (Object u _ _) = hashWithSalt s u
instance Show Object where
  -- it's not right to call 'atomically' here to read 'objSupers' for
  -- the show, as 'show' may be called from an stm transaction, stm
  -- will fail hard on encountering of nested 'atomically' calls.
  show (Object _ (ProcDefi _ _ (ProcDecl cn _ _)) _) =
    "<object: " ++ T.unpack cn ++ ">"

-- | View an entity as object of specified class with specified ancestors
-- this is the black magic you want to avoid
viewAsEdhObject :: Entity -> Class -> [Object] -> STM Object
viewAsEdhObject ent cls supers = Object ent cls <$> newTVar supers


-- | A world for Edh programs to change
data EdhWorld = EdhWorld {
    -- | root scope of this world
    worldScope :: !Scope
    -- | all scope wrapper objects in this world belong to the same
    -- class as 'scopeSuper' and have it as the top most super,
    -- the bottom super of a scope wraper object is the original
    -- `this` object of that scope, thus an attr addressor can be
    -- used to read the attribute value out of the wrapped scope, when
    -- the attr name does not conflict with scope wrapper methods
    , scopeSuper :: !Object
    -- | all operators declared in this world, this also used as the
    -- _world lock_ in parsing source code to be executed in this world
    , worldOperators :: !(TMVar OpPrecDict)
    -- | all modules loaded or being loaded into this world, for each
    -- entry, will be a transient entry containing an error value if
    -- failed loading, or a permanent entry containing the module object
    -- if successfully loaded
    , worldModules :: !(TMVar (Map.HashMap ModuleId (TMVar EdhValue)))
    -- | interface to the embedding host runtime
    , worldRuntime :: !EdhRuntime
  }
instance Eq EdhWorld where
  EdhWorld x'root _ _ _ _ == EdhWorld y'root _ _ _ _ = x'root == y'root

type ModuleId = Text

worldContext :: EdhWorld -> Context
worldContext !world = Context
  { contextWorld    = world
  , callStack       = worldScope world :| []
  , generatorCaller = Nothing
  , contextMatch    = true
  , contextStmt     = StmtSrc
                        ( SourcePos { sourceName   = "<genesis>"
                                    , sourceLine   = mkPos 1
                                    , sourceColumn = mkPos 1
                                    }
                        , VoidStmt
                        )
  }
{-# INLINE worldContext #-}


data EdhRuntime = EdhRuntime {
    consoleIO :: !(TQueue EdhConsoleIO)
  , runtimeLogLevel :: !LogLevel
  , runtimeLogger :: !EdhLogger
  , flushRuntimeLogs :: IO ()
  }
data EdhConsoleIO = ConsoleShutdown
    | ConsoleOut !Text
    -- ^ output line
    | ConsoleIn !(TMVar Text) !Text !Text
    -- ^ result-receiver ps1 ps2
  deriving (Eq)
type EdhLogger = LogLevel -> Maybe String -> ArgsPack -> STM ()
type LogLevel = Int


-- | The ultimate nothingness (Chinese 无极/無極), i.e. <nothing> out of <chaos>
wuji :: EdhProgState -> OriginalValue
wuji !pgs = OriginalValue nil rootScope $ thisObject rootScope
  where rootScope = worldScope $ contextWorld $ edh'context pgs
{-# INLINE wuji #-}


-- | The monad for running of an Edh program
type EdhMonad = ReaderT EdhProgState STM
type EdhProc = EdhMonad (STM ())

-- | The states of a program
data EdhProgState = EdhProgState {
    edh'fork'queue :: !(TQueue (Either (IO ()) EdhTxTask))
    , edh'task'queue :: !(TQueue EdhTxTask)
    , edh'reactors :: !(TVar [ReactorRecord])
    , edh'defers :: !(TVar [DeferRecord])
    , edh'in'tx :: !Bool
    , edh'context :: !Context
  }

type ReactorRecord = (TChan EdhValue, EdhProgState, ArgsReceiver, Expr)
type DeferRecord = (EdhProgState, EdhProc)

-- | Run an Edh proc from within STM monad
runEdhProc :: EdhProgState -> EdhProc -> STM ()
runEdhProc !pgs !p = join $ runReaderT p pgs
{-# INLINE runEdhProc #-}

-- | Fork a GHC thread to run the specified Edh proc concurrently
forkEdh :: EdhProcExit -> EdhProc -> EdhProc
forkEdh !exit !p = ask >>= \pgs -> contEdhSTM $ if edh'in'tx pgs
  then
    throwSTM
    $ EdhError UsageError "You don't fork within a transaction"
    $ getEdhCallContext 0 pgs
  else do
    writeTQueue (edh'fork'queue pgs) $ Right $ EdhTxTask pgs
                                                         False
                                                         (wuji pgs)
                                                         (const p)
    exitEdhSTM pgs exit nil

-- | Continue an Edh proc with stm computation, there must be NO further
-- action following this statement, or the stm computation is just lost.
--
-- Note: this is just `return`, but procedures writen in the host language
-- (i.e. Haskell) with this instead of `return` will be more readable.
contEdhSTM :: STM () -> EdhProc
contEdhSTM = return
{-# INLINE contEdhSTM #-}

-- | Convenient function to be used as short-hand to return from an Edh
-- procedure (or functions with similar signature), this sets transaction
-- boundaries wrt tx stated in the program's current state.
exitEdhProc :: EdhProcExit -> EdhValue -> EdhProc
exitEdhProc !exit !val = ask >>= \pgs -> contEdhSTM $ exitEdhSTM pgs exit val
{-# INLINE exitEdhProc #-}
exitEdhProc' :: EdhProcExit -> OriginalValue -> EdhProc
exitEdhProc' !exit !result =
  ask >>= \pgs -> contEdhSTM $ exitEdhSTM' pgs exit result
{-# INLINE exitEdhProc' #-}

-- | Exit an stm computation to the specified Edh continuation
exitEdhSTM :: EdhProgState -> EdhProcExit -> EdhValue -> STM ()
exitEdhSTM !pgs !exit !val =
  let !scope  = contextScope $ edh'context pgs
      !result = OriginalValue { valueFromOrigin = val
                              , originScope     = scope
                              , originObject    = thatObject scope
                              }
  in  exitEdhSTM' pgs exit result
{-# INLINE exitEdhSTM #-}
exitEdhSTM' :: EdhProgState -> EdhProcExit -> OriginalValue -> STM ()
exitEdhSTM' !pgs !exit !result = if edh'in'tx pgs
  then join $ runReaderT (exit result) pgs
  else writeTQueue (edh'task'queue pgs) $ EdhTxTask pgs False result exit
{-# INLINE exitEdhSTM' #-}

-- | An atomic task, an Edh program is composed of many this kind of tasks.
data EdhTxTask = EdhTxTask {
    edh'task'pgs :: !EdhProgState
    , edh'task'wait :: !Bool
    , edh'task'input :: !OriginalValue
    , edh'task'job :: !(OriginalValue -> EdhProc)
  }

-- | Type of an intrinsic infix operator in host language.
--
-- Note no stack frame is created/pushed when an intrinsic operator is called.
type EdhIntrinsicOp = Expr -> Expr -> EdhProcExit -> EdhProc

data IntrinOpDefi = IntrinOpDefi {
      intrinsic'op'uniq :: !Unique
    , intrinsic'op'symbol :: !AttrName
    , intrinsic'op :: EdhIntrinsicOp
  }

-- | Type of a procedure in host language that can be called from Edh code.
--
-- Note the top frame of the call stack from program state is the one for the
-- callee, that scope should have mounted the caller's scope entity, not a new
-- entity in contrast to when an Edh procedure as the callee.
type EdhProcedure -- such a procedure servs as the callee
  =  ArgsPack    -- ^ the pack of arguments
  -> EdhProcExit -- ^ the CPS exit to return a value from this procedure
  -> EdhProc

-- | The type for an Edh procedure's return, in continuation passing style.
type EdhProcExit = OriginalValue -> EdhProc

-- | An Edh value with the origin where it came from
data OriginalValue = OriginalValue {
    valueFromOrigin :: !EdhValue
    -- | the scope from which this value is addressed off
    , originScope :: !Scope
    -- | the attribute resolution target object in obtaining this value
    , originObject :: !Object
  }


-- | A no-operation as an Edh procedure, ignoring any arg
edhNop :: EdhProcedure
edhNop _ !exit = do
  pgs <- ask
  let scope = contextScope $ edh'context pgs
  exit $ OriginalValue nil scope $ thisObject scope

-- | A CPS exit serving end-of-procedure
edhEndOfProc :: EdhProcExit
edhEndOfProc _ = return $ return ()

-- | Construct an call context from program state
getEdhCallContext :: Int -> EdhProgState -> EdhCallContext
getEdhCallContext !unwind !pgs = EdhCallContext
  (T.pack $ sourcePosPretty tip)
  frames
 where
  unwindStack :: Int -> [Scope] -> [Scope]
  unwindStack c s | c <= 0 = s
  unwindStack _ []         = []
  unwindStack _ [f    ]    = [f]
  unwindStack c (_ : s)    = unwindStack (c - 1) s
  !ctx                = edh'context pgs
  (StmtSrc (!tip, _)) = contextStmt ctx
  !frames =
    foldl'
        (\sfs (Scope _ _ _ _ (ProcDefi _ _ (ProcDecl procName _ procBody)) (StmtSrc (callerPos, _))) ->
          EdhCallFrame procName
                       (procSrcLoc procBody)
                       (T.pack $ sourcePosPretty callerPos)
            : sfs
        )
        []
      $ unwindStack unwind
      $ NE.init (callStack ctx)
  procSrcLoc :: Either StmtSrc EdhProcedure -> Text
  procSrcLoc !procBody = case procBody of
    Left  (StmtSrc (spos, _)) -> T.pack (sourcePosPretty spos)
    Right _                   -> "<host-code>"


-- | A pack of evaluated argument values with positional/keyword origin,
-- normally obtained by invoking `packEdhArgs ctx argsSender`.
data ArgsPack = ArgsPack {
    positional'args :: ![EdhValue]
    , keyword'args :: !(Map.HashMap AttrName EdhValue)
  } deriving (Eq)
instance Hashable ArgsPack where
  hashWithSalt s (ArgsPack args kwargs) =
    foldl' (\s' (k, v) -> s' `hashWithSalt` k `hashWithSalt` v)
           (foldl' hashWithSalt s args)
      $ Map.toList kwargs
instance Show ArgsPack where
  show (ArgsPack posArgs kwArgs) = if null posArgs && Map.null kwArgs
    then "()"
    else
      "( "
      ++ concat [ show i ++ ", " | i <- posArgs ]
      ++ concat
           [ T.unpack kw ++ "=" ++ show v ++ ", "
           | (kw, v) <- Map.toList kwArgs
           ]
      ++ ")"


-- | An event sink is similar to a Go channel, but is broadcast
-- in nature, in contrast to the unicast nature of channels in Go.
data EventSink = EventSink {
    evs'uniq :: !Unique
    -- | sequence number, increased on every new event posting.
    -- must read zero when no event has ever been posted to this sink,
    -- non-zero otherwise. monotonicly increasing most of the time,
    -- but allowed to wrap back to 1 when exceeded 'maxBound::Int'
    -- negative values can be used to indicate abnormal conditions.
    , evs'seqn :: !(TVar Int)
    -- | most recent value, not valid until evs'seqn turns non-zero
    , evs'mrv :: !(TVar EdhValue)
    -- | the broadcast channel
    , evs'chan :: !(TChan EdhValue)
    -- | subscriber counter
    , evs'subc :: !(TVar Int)
  }
instance Eq EventSink where
  EventSink x'u _ _ _ _ == EventSink y'u _ _ _ _ = x'u == y'u
instance Ord EventSink where
  compare (EventSink x'u _ _ _ _) (EventSink y'u _ _ _ _) = compare x'u y'u
instance Hashable EventSink where
  hashWithSalt s (EventSink s'u _ _ _ _) = hashWithSalt s s'u
instance Show EventSink where
  show EventSink{} = "<sink>"


-- Atop Haskell, most types in Edh the surface language, are for
-- immutable values, besides dict and list, the only other mutable
-- data structure in Edh, is the entity, an **entity** is a set of
-- mutable attributes.
--
-- After applied a set of rules/constraints about how attributes
-- of an entity can be retrived and altered, it becomes an object.
--
-- Theoretically an entity is not necessarily mandated to have an
-- `identity` attribute among others, while practically the memory
-- address for physical storage of the attribute set, naturally
-- serves an `identity` attribute in single-process + single-run
-- scenario. Distributed programs, especially using a separate
-- database for storage, will tend to define a generated UUID 
-- attribute or the like.

-- | everything in Edh is a value
data EdhValue =
  -- | type itself is a kind of (immutable) value
      EdhType !EdhTypeValue
  -- | end values (immutable)
    | EdhNil
    | EdhDecimal !Decimal
    | EdhBool !Bool
    | EdhString !Text
    | EdhSymbol !Symbol

  -- | direct pointer (to entities) values
    | EdhObject !Object

  -- | mutable containers
    | EdhDict !Dict
    | EdhList !List

  -- | immutable containers
  --   the elements may still pointer to mutable data
    | EdhPair !EdhValue !EdhValue
    | EdhTuple ![EdhValue]
    | EdhArgsPack ArgsPack

  -- executable precedures
    | EdhIntrOp !Precedence !IntrinOpDefi
    | EdhClass !ProcDefi
    | EdhMethod !ProcDefi
    | EdhOprtor !Precedence !(Maybe EdhValue) !ProcDefi
    | EdhGnrtor !ProcDefi
    | EdhIntrpr !ProcDefi
    | EdhPrducr !ProcDefi

  -- | flow control
    | EdhBreak
    | EdhContinue
    | EdhCaseClose !EdhValue
    | EdhFallthrough
    | EdhYield !EdhValue
    | EdhReturn !EdhValue

  -- | event sink
    | EdhSink !EventSink

  -- | named value
    | EdhNamedValue !AttrName !EdhValue

  -- | reflective expr, with source (or not, if empty)
    | EdhExpr !Unique !Expr !Text

edhValueNull :: EdhValue -> STM Bool
edhValueNull EdhNil                  = return True
edhValueNull (EdhDecimal d         ) = return $ D.decimalIsNaN d || d == 0
edhValueNull (EdhBool    b         ) = return $ not b
edhValueNull (EdhString  s         ) = return $ T.null s
edhValueNull (EdhSymbol  _         ) = return False
edhValueNull (EdhDict    (Dict _ d)) = Map.null <$> readTVar d
edhValueNull (EdhList    (List _ l)) = null <$> readTVar l
edhValueNull (EdhTuple   l         ) = return $ null l
edhValueNull (EdhArgsPack (ArgsPack args kwargs)) =
  return $ null args && Map.null kwargs
edhValueNull (EdhExpr _ (LitExpr NilLiteral) _) = return True
edhValueNull (EdhExpr _ (LitExpr (DecLiteral d)) _) =
  return $ D.decimalIsNaN d || d == 0
edhValueNull (EdhExpr _ (LitExpr (BoolLiteral b)) _) = return b
edhValueNull (EdhExpr _ (LitExpr (StringLiteral s)) _) = return $ T.null s
edhValueNull (EdhNamedValue _ v) = edhValueNull v
edhValueNull _ = return False

instance Show EdhValue where
  show (EdhType t)    = show t
  show EdhNil         = "nil"
  show (EdhDecimal v) = showDecimal v
  show (EdhBool    v) = if v then "true" else "false"
  show (EdhString  v) = show v
  show (EdhSymbol  v) = show v

  show (EdhObject  v) = show v

  show (EdhDict    v) = show v
  show (EdhList    v) = show v

  show (EdhPair k v ) = show k <> ":" <> show v
  show (EdhTuple v  ) = if null v
    then "()" -- no space should show in an empty tuple
    else -- advocate trailing comma here
         "( " ++ concat [ show i ++ ", " | i <- v ] ++ ")"
  show (EdhArgsPack v) = "pkargs" ++ show v

  show (EdhIntrOp preced (IntrinOpDefi _ opSym _)) =
    "<intrinsic: (" ++ T.unpack opSym ++ ") " ++ show preced ++ ">"
  show (EdhClass  (ProcDefi _ _ (ProcDecl pn _ _))) = T.unpack pn
  show (EdhMethod (ProcDefi _ _ (ProcDecl pn _ _))) = T.unpack pn
  show (EdhOprtor preced _ (ProcDefi _ _ (ProcDecl pn _ _))) =
    "<operator: (" ++ T.unpack pn ++ ") " ++ show preced ++ ">"
  show (EdhGnrtor (ProcDefi _ _ (ProcDecl pn _ _))) = T.unpack pn
  show (EdhIntrpr (ProcDefi _ _ (ProcDecl pn _ _))) = T.unpack pn
  show (EdhPrducr (ProcDefi _ _ (ProcDecl pn _ _))) = T.unpack pn

  show EdhBreak         = "<break>"
  show EdhContinue      = "<continue>"
  show (EdhCaseClose v) = "<caseclose: " ++ show v ++ ">"
  show EdhFallthrough   = "<fallthrough>"
  show (EdhYield  v)    = "<yield: " ++ show v ++ ">"
  show (EdhReturn v)    = "<return: " ++ show v ++ ">"

  show (EdhSink   v)    = show v

  show (EdhNamedValue n v@EdhNamedValue{}) =
    -- Edh operators are all left-associative, parenthesis needed
    T.unpack n <> " := (" <> show v <> ")"
  show (EdhNamedValue n v) = T.unpack n <> " := " <> show v

  show (EdhExpr _ x s    ) = if T.null s
    then -- source-less form
         "<expr: " ++ show x ++ ">"
    else -- source form
         T.unpack s

-- Note:
--
-- here is identity-wise equality i.e. pointer equality if mutable,
-- or value equality if immutable.
--
-- the semantics are different from value-wise equality especially
-- for types of:  object/dict/list

instance Eq EdhValue where
  EdhType x       == EdhType y       = x == y
  EdhNil          == EdhNil          = True
  EdhDecimal x    == EdhDecimal y    = x == y
  EdhBool    x    == EdhBool    y    = x == y
  EdhString  x    == EdhString  y    = x == y
  EdhSymbol  x    == EdhSymbol  y    = x == y

  EdhObject  x    == EdhObject  y    = x == y

  EdhDict    x    == EdhDict    y    = x == y
  EdhList    x    == EdhList    y    = x == y
  EdhPair x'k x'v == EdhPair y'k y'v = x'k == y'k && x'v == y'v
  EdhTuple    x   == EdhTuple    y   = x == y
  EdhArgsPack x   == EdhArgsPack y   = x == y

  EdhIntrOp _ (IntrinOpDefi x'u _ _) == EdhIntrOp _ (IntrinOpDefi y'u _ _) =
    x'u == y'u
  EdhClass  x                 == EdhClass  y                 = x == y
  EdhMethod x                 == EdhMethod y                 = x == y
  EdhOprtor _ _ x             == EdhOprtor _ _ y             = x == y
  EdhGnrtor x                 == EdhGnrtor y                 = x == y
  EdhIntrpr x                 == EdhIntrpr y                 = x == y
  EdhPrducr x                 == EdhPrducr y                 = x == y

  EdhBreak                    == EdhBreak                    = True
  EdhContinue                 == EdhContinue                 = True
  EdhCaseClose x              == EdhCaseClose y              = x == y
  EdhFallthrough              == EdhFallthrough              = True
-- todo: regard a yielded/returned value equal to the value itself ?
  EdhYield  x'v               == EdhYield  y'v               = x'v == y'v
  EdhReturn x'v               == EdhReturn y'v               = x'v == y'v

  EdhSink   x                 == EdhSink   y                 = x == y

  EdhNamedValue _ x'v         == EdhNamedValue _ y'v         = x'v == y'v
  EdhNamedValue _ x'v         == y                           = x'v == y
  x                           == EdhNamedValue _ y'v         = x == y'v

  EdhExpr _   (LitExpr x'l) _ == EdhExpr _   (LitExpr y'l) _ = x'l == y'l
  EdhExpr x'u _             _ == EdhExpr y'u _             _ = x'u == y'u

-- todo: support coercing equality ?
--       * without this, we are a strongly typed dynamic language
--       * with this, we'll be a weakly typed dynamic language
  _                           == _                           = False

instance Hashable EdhValue where
  hashWithSalt s (EdhType x) = hashWithSalt s $ 1 + fromEnum x
  hashWithSalt s EdhNil = hashWithSalt s (0 :: Int)
  hashWithSalt s (EdhDecimal x                      ) = hashWithSalt s x
  hashWithSalt s (EdhBool    x                      ) = hashWithSalt s x
  hashWithSalt s (EdhString  x                      ) = hashWithSalt s x
  hashWithSalt s (EdhSymbol  x                      ) = hashWithSalt s x
  hashWithSalt s (EdhObject  x                      ) = hashWithSalt s x

  hashWithSalt s (EdhDict    x                      ) = hashWithSalt s x
  hashWithSalt s (EdhList    x                      ) = hashWithSalt s x
  hashWithSalt s (EdhPair k v) = s `hashWithSalt` k `hashWithSalt` v
  hashWithSalt s (EdhTuple    x                     ) = foldl' hashWithSalt s x
  hashWithSalt s (EdhArgsPack x                     ) = hashWithSalt s x

  hashWithSalt s (EdhIntrOp _ (IntrinOpDefi x'u _ _)) = hashWithSalt s x'u
  hashWithSalt s (EdhClass  x                       ) = hashWithSalt s x
  hashWithSalt s (EdhMethod x                       ) = hashWithSalt s x
  hashWithSalt s (EdhOprtor _ _ x                   ) = hashWithSalt s x
  hashWithSalt s (EdhGnrtor x                       ) = hashWithSalt s x
  hashWithSalt s (EdhIntrpr x                       ) = hashWithSalt s x
  hashWithSalt s (EdhPrducr x                       ) = hashWithSalt s x

  hashWithSalt s EdhBreak = hashWithSalt s (-1 :: Int)
  hashWithSalt s EdhContinue = hashWithSalt s (-2 :: Int)
  hashWithSalt s (EdhCaseClose v) =
    s `hashWithSalt` (-3 :: Int) `hashWithSalt` v
  hashWithSalt s EdhFallthrough            = hashWithSalt s (-4 :: Int)
  hashWithSalt s (EdhYield v) = s `hashWithSalt` (-5 :: Int) `hashWithSalt` v
  hashWithSalt s (EdhReturn v) = s `hashWithSalt` (-6 :: Int) `hashWithSalt` v

  hashWithSalt s (EdhSink   x            ) = hashWithSalt s x

  hashWithSalt s (EdhNamedValue _ v      ) = hashWithSalt s v

  hashWithSalt s (EdhExpr _ (LitExpr l) _) = hashWithSalt s l
  hashWithSalt s (EdhExpr u _           _) = hashWithSalt s u


edhUltimate :: EdhValue -> EdhValue
edhUltimate (EdhNamedValue _ v) = edhUltimate v
edhUltimate v                   = v

edhExpr :: Expr -> STM EdhValue
edhExpr (ExprWithSrc !xpr !xprSrc) = do
  u <- unsafeIOToSTM newUnique
  return $ EdhExpr u xpr xprSrc
edhExpr x = do
  u <- unsafeIOToSTM newUnique
  return $ EdhExpr u x ""

nil :: EdhValue
nil = EdhNil

-- | Resembles `None` as in Python
--
-- assigning to `nil` in Edh is roughly the same of `delete` as
-- in JavaScript, and `del` as in Python. Assigning to `None`
-- will keep the dict entry or object attribute while still
-- carrying a semantic of *absence*.
edhNone :: EdhValue
edhNone = EdhNamedValue "None" EdhNil

-- | Similar to `None`
--
-- though we don't have `Maybe` monad in Edh, having a `Nothing`
-- carrying null semantic may be useful in some cases.
edhNothing :: EdhValue
edhNothing = EdhNamedValue "Nothing" EdhNil

-- | With `nil` converted to `None` so the result will never be `nil`.
--
-- As `nil` carries *delete* semantic in assignment, in some cases it's better
-- avoided.
noneNil :: EdhValue -> EdhValue
noneNil EdhNil = edhNone
noneNil !v     = v

nan :: EdhValue
nan = EdhDecimal D.nan

inf :: EdhValue
inf = EdhDecimal D.inf

true :: EdhValue
true = EdhBool True

false :: EdhValue
false = EdhBool False


newtype StmtSrc = StmtSrc (SourcePos, Stmt)
instance Eq StmtSrc where
  StmtSrc (x'sp, _) == StmtSrc (y'sp, _) = x'sp == y'sp
instance Show StmtSrc where
  show (StmtSrc (sp, stmt)) = show stmt ++ "\n@ " ++ sourcePosPretty sp


data Stmt =
      -- | literal `pass` to fill a place where a statement needed,
      -- same as in Python
      VoidStmt
      -- | atomically isolated, mark a code section for transaction bounds
    | AtoIsoStmt !Expr
      -- | similar to `go` in Go, starts goroutine
    | GoStmt !Expr
      -- | not similar to `defer` in Go (in Go `defer` snapshots arg values
      -- and schedules execution on func return), but in Edh `defer`
      -- schedules execution on thread termination
    | DeferStmt !Expr
      -- | import with args (re)pack receiving syntax
    | ImportStmt !ArgsReceiver !Expr
      -- | assignment with args (un/re)pack sending/receiving syntax
    | LetStmt !ArgsReceiver !ArgsSender
      -- | super object declaration for a descendant object
    | ExtendsStmt !Expr
      -- | class (constructor) procedure definition
    | ClassStmt !ProcDecl
      -- | method procedure definition
    | MethodStmt !ProcDecl
      -- | generator procedure definition
    | GeneratorStmt !ProcDecl
      -- | reactor declaration, a reactor procedure is not bound to a name,
      -- it's bound to an event `sink` with the calling thread as context,
      -- when an event fires from that event `sink`, the bound reactor will
      -- get run from the thread where it's declared, after the currernt
      -- transaction finishes, a reactor procedure can `break` to terminate
      -- the thread, or the thread will continue to process next reactor, or
      -- next transactional task normally
      -- the reactor mechanism is somewhat similar to traditional signal
      -- handling mechanism in OS process management
    | ReactorStmt !Expr !ArgsReceiver !Expr
      -- | interpreter declaration, an interpreter procedure is not otherwise
      -- different from a method procedure, except it receives arguments
      -- in expression form rather than values, in addition to the reflective
      -- `callerScope` as first argument
    | InterpreterStmt !ProcDecl
    | ProducerStmt !ProcDecl
      -- | while loop
    | WhileStmt !Expr !Expr
      -- | break from a while/for loop, or terminate the Edh thread if given
      -- from a reactor
    | BreakStmt
      -- | continue a while/for loop
    | ContinueStmt
      -- | similar to fallthrough in Go
    | FallthroughStmt
      -- | operator declaration
    | OpDeclStmt !OpSymbol !Precedence !ProcDecl
      -- | operator override
    | OpOvrdStmt !OpSymbol !ProcDecl !Precedence
      -- | any value can be thrown as exception, handling will rely on the
      --   ($=>) as `catch` and (@=>) as `finally` operators
    | ThrowStmt !Expr
      -- | early stop from a procedure
    | ReturnStmt !Expr
      -- | expression with precedence
    | ExprStmt !Expr
  deriving (Show)

-- Attribute addressor
data AttrAddr = ThisRef | ThatRef | SuperRef
    | DirectRef !AttrAddressor
    | IndirectRef !Expr !AttrAddressor
  deriving (Eq, Show)

data AttrAddressor =
    -- | vanilla form in addressing attributes against
    --   a left hand entity object
    NamedAttr !AttrName
    -- | get the symbol value from current entity,
    --   then use it to address attributes against
    --   a left hand entity object
    | SymbolicAttr !AttrName
  deriving (Eq, Show)


receivesNamedArg :: Text -> ArgsReceiver -> Bool
receivesNamedArg _     WildReceiver              = True
receivesNamedArg !name (SingleReceiver argRcvr ) = _hasNamedArg name [argRcvr]
receivesNamedArg !name (PackReceiver   argRcvrs) = _hasNamedArg name argRcvrs

_hasNamedArg :: Text -> [ArgReceiver] -> Bool
_hasNamedArg _     []           = False
_hasNamedArg !name (arg : rest) = case arg of
  RecvArg !argName _ _ -> argName == name || _hasNamedArg name rest
  _                    -> _hasNamedArg name rest

data ArgsReceiver = PackReceiver ![ArgReceiver]
    | SingleReceiver !ArgReceiver
    | WildReceiver
  deriving (Eq)
instance Show ArgsReceiver where
  show (PackReceiver   rs) = "( " ++ unwords ((++ ", ") . show <$> rs) ++ ")"
  show (SingleReceiver r ) = "(" ++ show r ++ ")"
  show WildReceiver        = "*"

data ArgReceiver = RecvRestPosArgs !AttrName
    | RecvRestKwArgs !AttrName
    | RecvRestPkArgs !AttrName
    | RecvArg !AttrName !(Maybe AttrAddr) !(Maybe Expr)
  deriving (Eq)
instance Show ArgReceiver where
  show (RecvRestPosArgs nm) = "*" ++ T.unpack nm
  show (RecvRestKwArgs  nm) = "**" ++ T.unpack nm
  show (RecvRestPkArgs  nm) = "***" ++ T.unpack nm
  show (RecvArg nm _ _    ) = T.unpack nm

type ArgsSender = [ArgSender]
data ArgSender = UnpackPosArgs !Expr
    | UnpackKwArgs !Expr
    | UnpackPkArgs !Expr
    | SendPosArg !Expr
    | SendKwArg !AttrName !Expr
  deriving (Eq, Show)

-- | Procedure declaration, result of parsing
data ProcDecl = ProcDecl {
      procedure'name :: !AttrName
    , procedure'args :: !ArgsReceiver
    , procedure'body :: !(Either StmtSrc EdhProcedure)
  }
instance Show ProcDecl where
  show (ProcDecl name _ pb) = case pb of
    Left  _ -> "<edh-proc " <> T.unpack name <> ">"
    Right _ -> "<host-proc " <> T.unpack name <> ">"

-- | Procedure definition, result of execution of the declaration
data ProcDefi = ProcDefi {
    procedure'uniq :: !Unique
    , procedure'lexi :: !(Maybe Scope)
    , procedure'decl :: {-# UNPACK #-} !ProcDecl
  }
instance Eq ProcDefi where
  ProcDefi x'u _ _ == ProcDefi y'u _ _ = x'u == y'u
instance Ord ProcDefi where
  compare (ProcDefi x'u _ _) (ProcDefi y'u _ _) = compare x'u y'u
instance Hashable ProcDefi where
  hashWithSalt s (ProcDefi u scope _) = s `hashWithSalt` u `hashWithSalt` scope
instance Show ProcDefi where
  show (ProcDefi _ _ decl) = show decl

lexicalScopeOf :: ProcDefi -> Scope
lexicalScopeOf (ProcDefi _ (Just scope) _) = scope
lexicalScopeOf (ProcDefi _ Nothing _) =
  error "bug: asking for scope of world root"


-- | The Edh class is a special type of procedure, receives no argument.
type Class = ProcDefi


data Prefix = PrefixPlus | PrefixMinus | Not
    -- | to disregard the match target in context,
    -- for a branch condition
    | Guard
  deriving (Eq, Show)

data Expr = LitExpr !Literal | PrefixExpr !Prefix !Expr
    | IfExpr { if'condition :: !Expr
            , if'consequence :: !Expr
            , if'alternative :: !(Maybe Expr)
            }
    | CaseExpr { case'target :: !Expr , case'branches :: !Expr }

    | DictExpr ![Expr] -- should all be Infix ":"
    | ListExpr ![Expr]
    | TupleExpr ![Expr]
    | ParenExpr !Expr

    -- | the block is made an expression in Edh, instead of a statement
    -- as in a C family language. it evaluates to the value of last expr
    -- within it, in case no `EdhCaseClose` encountered, or can stop
    -- early with the value from a `EdhCaseClose`, typically returned
    -- from the branch `(->)` operator.
    --
    -- this allows multiple statements grouped as a single expression
    -- fitting into subclauses of if-then-else, while, for-from-do,
    -- and try-catch-finally etc. where an expression is expected.
    -- 
    -- this also made possible for a method procedure to explicitly
    -- `return { continue }` to carry a semantic to the magic method
    -- caller that it should try next method, similar to what
    -- `NotImplemented` does in Python.
    | BlockExpr ![StmtSrc]

    | YieldExpr !Expr

    -- | a for-from-do loop is made an expression in Edh, so it can
    -- appear as the right-hand expr of the comprehension (=<) operator.
    | ForExpr !ArgsReceiver !Expr !Expr

    | AttrExpr !AttrAddr
    | IndexExpr { index'value :: !Expr
                , index'target :: !Expr
                }
    | CallExpr !Expr !ArgsSender

    | InfixExpr !OpSymbol !Expr !Expr

    | ExprWithSrc !Expr !Text

     -- for host (Haskell) code to bake some cake in
    | GodSendExpr !EdhValue
  deriving (Eq, Show)


data Literal = SinkCtor
    | NilLiteral
    | DecLiteral !Decimal
    | BoolLiteral !Bool
    | StringLiteral !Text
    | TypeLiteral !EdhTypeValue
  deriving (Eq, Show)
instance Hashable Literal where
  hashWithSalt s SinkCtor          = hashWithSalt s (-1 :: Int)
  hashWithSalt s NilLiteral        = hashWithSalt s (0 :: Int)
  hashWithSalt s (DecLiteral    x) = hashWithSalt s x
  hashWithSalt s (BoolLiteral   x) = hashWithSalt s x
  hashWithSalt s (StringLiteral x) = hashWithSalt s x
  hashWithSalt s (TypeLiteral   x) = hashWithSalt s x


-- | the type for the value of type of a value
data EdhTypeValue = TypeType
    -- nil has no type, its type if you really ask, is nil
    | DecimalType
    | BoolType
    | StringType
    | SymbolType
    | ObjectType
    | DictType
    | ListType
    | PairType
    | TupleType
    | ArgsPackType
    | BlockType
    | HostClassType
    | HostMethodType
    | HostOperType
    | HostGenrType
    | IntrinsicType
    | ClassType
    | MethodType
    | OperatorType
    | GeneratorType
    | InterpreterType
    | ProducerType
    | BreakType
    | ContinueType
    | CaseCloseType
    | FallthroughType
    | YieldType
    | ReturnType
    | SinkType
    | ExprType
  deriving (Enum, Eq, Ord, Show)
instance Hashable EdhTypeValue where
  hashWithSalt s t = hashWithSalt s $ fromEnum t

edhTypeNameOf :: EdhValue -> String
edhTypeNameOf EdhNil = "nil"
edhTypeNameOf v      = show $ edhTypeOf v

-- | Get the type tag of an value
--
-- Passing in a `nil` value will hit bottom (crash the process) here,
-- use `edhTypeNameOf` if all you want is a type name shown to user.
edhTypeOf :: EdhValue -> EdhTypeValue
edhTypeOf EdhNil = --
  undefined        -- this is a taboo

edhTypeOf EdhType{}                                   = TypeType

edhTypeOf EdhDecimal{}                                = DecimalType
edhTypeOf EdhBool{}                                   = BoolType
edhTypeOf EdhString{}                                 = StringType
edhTypeOf EdhSymbol{}                                 = SymbolType
edhTypeOf EdhObject{}                                 = ObjectType
edhTypeOf EdhDict{}                                   = DictType
edhTypeOf EdhList{}                                   = ListType
edhTypeOf EdhPair{}                                   = PairType
edhTypeOf EdhTuple{}                                  = TupleType
edhTypeOf EdhArgsPack{}                               = ArgsPackType

edhTypeOf EdhIntrOp{}                                 = IntrinsicType
edhTypeOf (EdhClass (ProcDefi _ _ (ProcDecl _ _ pb))) = case pb of
  Left  _ -> ClassType
  Right _ -> HostClassType
edhTypeOf (EdhMethod (ProcDefi _ _ (ProcDecl _ _ pb))) = case pb of
  Left  _ -> MethodType
  Right _ -> HostMethodType
edhTypeOf (EdhOprtor _ _ (ProcDefi _ _ (ProcDecl _ _ pb))) = case pb of
  Left  _ -> OperatorType
  Right _ -> HostOperType
edhTypeOf (EdhGnrtor (ProcDefi _ _ (ProcDecl _ _ pb))) = case pb of
  Left  _ -> GeneratorType
  Right _ -> HostGenrType

edhTypeOf EdhIntrpr{}         = InterpreterType
edhTypeOf EdhPrducr{}         = ProducerType
edhTypeOf EdhBreak            = BreakType
edhTypeOf EdhContinue         = ContinueType
edhTypeOf EdhCaseClose{}      = CaseCloseType
edhTypeOf EdhFallthrough      = FallthroughType
edhTypeOf EdhYield{}          = YieldType
edhTypeOf EdhReturn{}         = ReturnType
edhTypeOf EdhSink{}           = SinkType
edhTypeOf (EdhNamedValue _ v) = edhTypeOf v
edhTypeOf EdhExpr{}           = ExprType
