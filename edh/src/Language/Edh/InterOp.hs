{-# LANGUAGE PatternSynonyms #-}

module Language.Edh.InterOp where


import           Prelude

import           GHC.Conc                       ( unsafeIOToSTM )
-- import           System.IO.Unsafe               ( unsafePerformIO )

import           GHC.TypeLits                   ( KnownSymbol
                                                , symbolVal
                                                )

import           Control.Monad
import           Control.Concurrent.STM

import           Data.Unique
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import           Data.ByteString                ( ByteString )
import qualified Data.HashMap.Strict           as Map

import           Data.Proxy
import           Data.Dynamic

import qualified Data.UUID                     as UUID

import           Text.Megaparsec

import           Data.Lossless.Decimal         as D

import           Language.Edh.Control
import           Language.Edh.Args

import           Language.Edh.Details.IOPD
import           Language.Edh.Details.CoreLang
import           Language.Edh.Details.RtTypes
import           Language.Edh.Details.Evaluate


mkHostClass'
  :: Scope
  -> AttrName
  -> (ArgsPack -> EdhObjectAllocator)
  -> EntityStore
  -> [Object]
  -> STM Object
mkHostClass' !scope !className !allocator !classStore !superClasses = do
  !idCls  <- unsafeIOToSTM newUnique
  !ssCls  <- newTVar superClasses
  !mroCls <- newTVar []
  let !clsProc = ProcDefi idCls (AttrByName className) scope
        $ ProcDecl (NamedAttr className) (PackReceiver []) (Right fakeHostProc)
      !cls    = Class clsProc classStore allocator mroCls
      !clsObj = Object idCls (ClassStore cls) metaClassObj ssCls
  !mroInvalid <- fillClassMRO cls superClasses
  unless (T.null mroInvalid)
    $ throwSTM
    $ EdhError UsageError mroInvalid (toDyn nil)
    $ EdhCallContext "<mkHostClass>" []
  return clsObj
 where
  fakeHostProc :: ArgsPack -> EdhHostProc
  fakeHostProc _ !exit = exitEdhTx exit nil

  !metaClassObj =
    edh'obj'class $ edh'obj'class $ edh'scope'this $ rootScopeOf scope

mkHostClass
  :: Scope
  -> AttrName
  -> (ArgsPack -> EdhObjectAllocator)
  -> [Object]
  -> (Scope -> STM ())
  -> STM Object
mkHostClass !scope !className !allocator !superClasses !storeMod = do
  !classStore <- iopdEmpty
  !idCls      <- unsafeIOToSTM newUnique
  !ssCls      <- newTVar superClasses
  !mroCls     <- newTVar []
  let !clsProc = ProcDefi idCls (AttrByName className) scope
        $ ProcDecl (NamedAttr className) (PackReceiver []) (Right fakeHostProc)
      !cls      = Class clsProc classStore allocator mroCls
      !clsObj   = Object idCls (ClassStore cls) metaClassObj ssCls
      !clsScope = scope { edh'scope'entity  = classStore
                        , edh'scope'this    = clsObj
                        , edh'scope'that    = clsObj
                        , edh'excpt'hndlr   = defaultEdhExcptHndlr
                        , edh'scope'proc    = clsProc
                        , edh'scope'caller  = clsCreStmt
                        , edh'effects'stack = []
                        }
  storeMod clsScope
  !mroInvalid <- fillClassMRO cls superClasses
  unless (T.null mroInvalid)
    $ throwSTM
    $ EdhError UsageError mroInvalid (toDyn nil)
    $ EdhCallContext "<mkHostClass>" []
  return clsObj
 where
  fakeHostProc :: ArgsPack -> EdhHostProc
  fakeHostProc _ !exit = exitEdhTx exit nil

  !metaClassObj =
    edh'obj'class $ edh'obj'class $ edh'scope'this $ rootScopeOf scope

  clsCreStmt :: StmtSrc
  clsCreStmt = StmtSrc
    ( SourcePos { sourceName   = "<host-class-creation>"
                , sourceLine   = mkPos 1
                , sourceColumn = mkPos 1
                }
    , VoidStmt
    )


-- | Class for an object allocator implemented in the host language (which is
-- Haskell) that can be called from Edh code.
class EdhAllocator fn where
  allocEdhObj :: fn -> ArgsPack -> EdhAllocExit -> EdhTx


-- nullary base case
instance EdhAllocator (EdhAllocExit -> EdhTx) where
  allocEdhObj !fn apk@(ArgsPack !args !kwargs) !exit =
    if null args && odNull kwargs
      then fn exit
      else \ !ets -> edhValueRepr ets (EdhArgsPack apk) $ \ !badRepr ->
        throwEdh ets UsageError $ "extraneous arguments: " <> badRepr

-- repack rest-positional-args
instance EdhAllocator fn' => EdhAllocator ([EdhValue] -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    allocEdhObj (fn args) (ArgsPack [] kwargs) exit

-- repack rest-keyword-args
instance EdhAllocator fn' => EdhAllocator (OrderedDict AttrKey EdhValue -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    allocEdhObj (fn kwargs) (ArgsPack args odEmpty) exit

-- repack rest-pack-args
-- note it'll cause runtime error if @fn'@ takes further args
instance EdhAllocator fn' => EdhAllocator (ArgsPack -> fn') where
  allocEdhObj !fn !apk !exit = allocEdhObj (fn apk) (ArgsPack [] odEmpty) exit

-- receive positional-only arg taking 'EdhValue'
instance EdhAllocator fn' => EdhAllocator (EdhValue -> fn') where
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit =
    allocEdhObj (fn val) (ArgsPack args kwargs) exit
  allocEdhObj _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'EdhValue'
instance EdhAllocator fn' => EdhAllocator (Maybe EdhValue -> fn') where
  allocEdhObj !fn (ArgsPack [] !kwargs) !exit =
    allocEdhObj (fn Nothing) (ArgsPack [] kwargs) exit
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit =
    allocEdhObj (fn (Just val)) (ArgsPack args kwargs) exit

-- receive positional-only arg taking 'EdhTypeValue'
instance EdhAllocator fn' => EdhAllocator (EdhTypeValue -> fn') where
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhType !val' -> allocEdhObj (fn val') (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"
  allocEdhObj _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'EdhTypeValue'
instance EdhAllocator fn' => EdhAllocator (Maybe EdhTypeValue -> fn') where
  allocEdhObj !fn (ArgsPack [] !kwargs) !exit =
    allocEdhObj (fn Nothing) (ArgsPack [] kwargs) exit
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhType !val' -> allocEdhObj (fn (Just val')) (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'Decimal'
instance EdhAllocator fn' => EdhAllocator (Decimal -> fn') where
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhDecimal !val' -> allocEdhObj (fn val') (ArgsPack args kwargs) exit
    _                -> throwEdhTx UsageError "arg type mismatch: anonymous"
  allocEdhObj _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'Decimal'
instance EdhAllocator fn' => EdhAllocator (Maybe Decimal -> fn') where
  allocEdhObj !fn (ArgsPack [] !kwargs) !exit =
    allocEdhObj (fn Nothing) (ArgsPack [] kwargs) exit
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhDecimal !val' ->
      allocEdhObj (fn (Just val')) (ArgsPack args kwargs) exit
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'Integer'
instance EdhAllocator fn' => EdhAllocator (Integer -> fn') where
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhDecimal !val' -> case D.decimalToInteger val' of
      Just !i -> allocEdhObj (fn i) (ArgsPack args kwargs) exit
      _       -> throwEdhTx UsageError "number type mismatch: anonymous"
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"
  allocEdhObj _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'Integer'
instance EdhAllocator fn' => EdhAllocator (Maybe Integer -> fn') where
  allocEdhObj !fn (ArgsPack [] !kwargs) !exit =
    allocEdhObj (fn Nothing) (ArgsPack [] kwargs) exit
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhDecimal !val' -> case D.decimalToInteger val' of
      Just !i -> allocEdhObj (fn (Just i)) (ArgsPack args kwargs) exit
      _       -> throwEdhTx UsageError "number type mismatch: anonymous"
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'Int'
instance EdhAllocator fn' => EdhAllocator (Int -> fn') where
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhDecimal !val' -> case D.decimalToInteger val' of
      Just !i -> allocEdhObj (fn $ fromInteger i) (ArgsPack args kwargs) exit
      _       -> throwEdhTx UsageError "number type mismatch: anonymous"
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"
  allocEdhObj _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'Int'
instance EdhAllocator fn' => EdhAllocator (Maybe Int -> fn') where
  allocEdhObj !fn (ArgsPack [] !kwargs) !exit =
    allocEdhObj (fn Nothing) (ArgsPack [] kwargs) exit
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhDecimal !val' -> case D.decimalToInteger val' of
      Just !i ->
        allocEdhObj (fn (Just $ fromInteger i)) (ArgsPack args kwargs) exit
      _ -> throwEdhTx UsageError "number type mismatch: anonymous"
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'Bool'
instance EdhAllocator fn' => EdhAllocator (Bool -> fn') where
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhBool !val' -> allocEdhObj (fn val') (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"
  allocEdhObj _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'Bool'
instance EdhAllocator fn' => EdhAllocator (Maybe Bool -> fn') where
  allocEdhObj !fn (ArgsPack [] !kwargs) !exit =
    allocEdhObj (fn Nothing) (ArgsPack [] kwargs) exit
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhBool !val' -> allocEdhObj (fn (Just val')) (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'Blob'
instance EdhAllocator fn' => EdhAllocator (ByteString -> fn') where
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhBlob !val' -> allocEdhObj (fn val') (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"
  allocEdhObj _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'Blob'
instance EdhAllocator fn' => EdhAllocator (Maybe ByteString -> fn') where
  allocEdhObj !fn (ArgsPack [] !kwargs) !exit =
    allocEdhObj (fn Nothing) (ArgsPack [] kwargs) exit
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhBlob !val' -> allocEdhObj (fn (Just val')) (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'Text'
instance EdhAllocator fn' => EdhAllocator (Text -> fn') where
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhString !val' -> allocEdhObj (fn val') (ArgsPack args kwargs) exit
    _               -> throwEdhTx UsageError "arg type mismatch: anonymous"
  allocEdhObj _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'Text'
instance EdhAllocator fn' => EdhAllocator (Maybe Text -> fn') where
  allocEdhObj !fn (ArgsPack [] !kwargs) !exit =
    allocEdhObj (fn Nothing) (ArgsPack [] kwargs) exit
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhString !val' -> allocEdhObj (fn (Just val')) (ArgsPack args kwargs) exit
    _               -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'Symbol'
instance EdhAllocator fn' => EdhAllocator (Symbol -> fn') where
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhSymbol !val' -> allocEdhObj (fn val') (ArgsPack args kwargs) exit
    _               -> throwEdhTx UsageError "arg type mismatch: anonymous"
  allocEdhObj _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'Symbol'
instance EdhAllocator fn' => EdhAllocator (Maybe Symbol -> fn') where
  allocEdhObj !fn (ArgsPack [] !kwargs) !exit =
    allocEdhObj (fn Nothing) (ArgsPack [] kwargs) exit
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhSymbol !val' -> allocEdhObj (fn (Just val')) (ArgsPack args kwargs) exit
    _               -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'UUID'
instance EdhAllocator fn' => EdhAllocator (UUID.UUID -> fn') where
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhUUID !val' -> allocEdhObj (fn val') (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"
  allocEdhObj _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'UUID'
instance EdhAllocator fn' => EdhAllocator (Maybe UUID.UUID -> fn') where
  allocEdhObj !fn (ArgsPack [] !kwargs) !exit =
    allocEdhObj (fn Nothing) (ArgsPack [] kwargs) exit
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhUUID !val' -> allocEdhObj (fn (Just val')) (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'EdhPair'
instance EdhAllocator fn' => EdhAllocator ((EdhValue, EdhValue) -> fn') where
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhPair !v1 !v2 -> allocEdhObj (fn (v1, v2)) (ArgsPack args kwargs) exit
    _               -> throwEdhTx UsageError "arg type mismatch: anonymous"
  allocEdhObj _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'EdhPair'
instance EdhAllocator fn' => EdhAllocator (Maybe (EdhValue, EdhValue) -> fn') where
  allocEdhObj !fn (ArgsPack [] !kwargs) !exit =
    allocEdhObj (fn Nothing) (ArgsPack [] kwargs) exit
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhPair !v1 !v2 ->
      allocEdhObj (fn (Just (v1, v2))) (ArgsPack args kwargs) exit
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'Dict'
instance EdhAllocator fn' => EdhAllocator (Dict -> fn') where
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhDict !val' -> allocEdhObj (fn val') (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"
  allocEdhObj _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'Dict'
instance EdhAllocator fn' => EdhAllocator (Maybe Dict -> fn') where
  allocEdhObj !fn (ArgsPack [] !kwargs) !exit =
    allocEdhObj (fn Nothing) (ArgsPack [] kwargs) exit
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhDict !val' -> allocEdhObj (fn (Just val')) (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'List'
instance EdhAllocator fn' => EdhAllocator (List -> fn') where
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhList !val' -> allocEdhObj (fn val') (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"
  allocEdhObj _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'List'
instance EdhAllocator fn' => EdhAllocator (Maybe List -> fn') where
  allocEdhObj !fn (ArgsPack [] !kwargs) !exit =
    allocEdhObj (fn Nothing) (ArgsPack [] kwargs) exit
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhList !val' -> allocEdhObj (fn (Just val')) (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'Object'
instance EdhAllocator fn' => EdhAllocator (Object -> fn') where
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhObject !val' -> allocEdhObj (fn val') (ArgsPack args kwargs) exit
    _               -> throwEdhTx UsageError "arg type mismatch: anonymous"
  allocEdhObj _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'Object'
instance EdhAllocator fn' => EdhAllocator (Maybe Object -> fn') where
  allocEdhObj !fn (ArgsPack [] !kwargs) !exit =
    allocEdhObj (fn Nothing) (ArgsPack [] kwargs) exit
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhObject !val' -> allocEdhObj (fn (Just val')) (ArgsPack args kwargs) exit
    _               -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'EdhOrd'
instance EdhAllocator fn' => EdhAllocator (Ordering -> fn') where
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhOrd !val' -> allocEdhObj (fn val') (ArgsPack args kwargs) exit
    _            -> throwEdhTx UsageError "arg type mismatch: anonymous"
  allocEdhObj _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'EdhOrd'
instance EdhAllocator fn' => EdhAllocator (Maybe Ordering -> fn') where
  allocEdhObj !fn (ArgsPack [] !kwargs) !exit =
    allocEdhObj (fn Nothing) (ArgsPack [] kwargs) exit
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhOrd !val' -> allocEdhObj (fn (Just val')) (ArgsPack args kwargs) exit
    _            -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'EventSink'
instance EdhAllocator fn' => EdhAllocator (EventSink -> fn') where
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhSink !val' -> allocEdhObj (fn val') (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"
  allocEdhObj _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'EventSink'
instance EdhAllocator fn' => EdhAllocator (Maybe EventSink -> fn') where
  allocEdhObj !fn (ArgsPack [] !kwargs) !exit =
    allocEdhObj (fn Nothing) (ArgsPack [] kwargs) exit
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhSink !val' -> allocEdhObj (fn (Just val')) (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'EdhNamedValue'
instance EdhAllocator fn' => EdhAllocator ((AttrName,EdhValue) -> fn') where
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhNamedValue !name !value ->
      allocEdhObj (fn (name, value)) (ArgsPack args kwargs) exit
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"
  allocEdhObj _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'EdhNamedValue'
instance EdhAllocator fn' => EdhAllocator (Maybe (AttrName,EdhValue) -> fn') where
  allocEdhObj !fn (ArgsPack [] !kwargs) !exit =
    allocEdhObj (fn Nothing) (ArgsPack [] kwargs) exit
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhNamedValue !name !value ->
      allocEdhObj (fn (Just (name, value))) (ArgsPack args kwargs) exit
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'EdhExpr'
instance EdhAllocator fn' => EdhAllocator ((Expr,Text) -> fn') where
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhExpr _ !expr !src ->
      allocEdhObj (fn (expr, src)) (ArgsPack args kwargs) exit
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"
  allocEdhObj _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'EdhExpr'
instance EdhAllocator fn' => EdhAllocator (Maybe (Expr,Text) -> fn') where
  allocEdhObj !fn (ArgsPack [] !kwargs) !exit =
    allocEdhObj (fn Nothing) (ArgsPack [] kwargs) exit
  allocEdhObj !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhExpr _ !expr !src ->
      allocEdhObj (fn (Just (expr, src))) (ArgsPack args kwargs) exit
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"


-- receive named arg taking 'EdhValue'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg EdhValue name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, kwargs') ->
        allocEdhObj (fn (NamedEdhArg val)) (ArgsPack args kwargs') exit
      (Nothing, kwargs') -> case args of
        [] -> throwEdhTx UsageError $ "missing named arg: " <> argName
        (val : args') ->
          allocEdhObj (fn (NamedEdhArg val)) (ArgsPack args' kwargs') exit
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'EdhValue'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Maybe EdhValue) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Nothing, !kwargs') -> case args of
        [] -> allocEdhObj (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> allocEdhObj (fn (NamedEdhArg (Just val)))
                                   (ArgsPack args' kwargs')
                                   exit
      (!maybeVal, !kwargs') ->
        allocEdhObj (fn (NamedEdhArg maybeVal)) (ArgsPack args kwargs') exit
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'EdhTypeValue'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg EdhTypeValue name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhType !val' ->
          allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhType !val' ->
            allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'EdhTypeValue'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Maybe EdhTypeValue) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhType !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                     (ArgsPack args kwargs')
                                     exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> allocEdhObj (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhType !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args' kwargs')
                                       exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'Decimal'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg Decimal name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhDecimal !val' ->
          allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhDecimal !val' ->
            allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'Decimal'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Maybe Decimal) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhDecimal !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                        (ArgsPack args kwargs')
                                        exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> allocEdhObj (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhDecimal !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                          (ArgsPack args' kwargs')
                                          exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'Integer'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg Integer name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhDecimal !val' -> case D.decimalToInteger val' of
          Just !i ->
            allocEdhObj (fn (NamedEdhArg i)) (ArgsPack args kwargs') exit
          _ -> throwEdhTx UsageError $ "number type mismatch: " <> argName
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhDecimal !val' -> case D.decimalToInteger val' of
            Just !i ->
              allocEdhObj (fn (NamedEdhArg i)) (ArgsPack args' kwargs') exit
            _ -> throwEdhTx UsageError $ "number type mismatch: " <> argName
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'Integer'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Maybe Integer) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhDecimal !val' -> case D.decimalToInteger val' of
          Just !i ->
            allocEdhObj (fn (NamedEdhArg (Just i))) (ArgsPack args kwargs') exit
          _ -> throwEdhTx UsageError $ "number type mismatch: " <> argName
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> allocEdhObj (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhDecimal !val' -> case D.decimalToInteger val' of
            Just !i -> allocEdhObj (fn (NamedEdhArg (Just i)))
                                   (ArgsPack args' kwargs')
                                   exit
            _ -> throwEdhTx UsageError $ "number type mismatch: " <> argName
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'Int'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg Int name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhDecimal !val' -> case D.decimalToInteger val' of
          Just !i -> allocEdhObj (fn (NamedEdhArg $ fromInteger i))
                                 (ArgsPack args kwargs')
                                 exit
          _ -> throwEdhTx UsageError $ "number type mismatch: " <> argName
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhDecimal !val' -> case D.decimalToInteger val' of
            Just !i -> allocEdhObj (fn (NamedEdhArg $ fromInteger i))
                                   (ArgsPack args' kwargs')
                                   exit
            _ -> throwEdhTx UsageError $ "number type mismatch: " <> argName
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'Int'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Maybe Int) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhDecimal !val' -> case D.decimalToInteger val' of
          Just !i -> allocEdhObj (fn (NamedEdhArg (Just $ fromInteger i)))
                                 (ArgsPack args kwargs')
                                 exit
          _ -> throwEdhTx UsageError $ "number type mismatch: " <> argName
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> allocEdhObj (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhDecimal !val' -> case D.decimalToInteger val' of
            Just !i -> allocEdhObj (fn (NamedEdhArg (Just $ fromInteger i)))
                                   (ArgsPack args' kwargs')
                                   exit
            _ -> throwEdhTx UsageError $ "number type mismatch: " <> argName
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'Bool'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg Bool name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhBool !val' ->
          allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhBool !val' ->
            allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'Bool'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Maybe Bool) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhBool !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                     (ArgsPack args kwargs')
                                     exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> allocEdhObj (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhBool !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args' kwargs')
                                       exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'ByteString'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg ByteString name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhBlob !val' ->
          allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhBlob !val' ->
            allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'ByteString'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Maybe ByteString) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhBlob !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                     (ArgsPack args kwargs')
                                     exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> allocEdhObj (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhBlob !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args' kwargs')
                                       exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'Text'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg Text name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhString !val' ->
          allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhString !val' ->
            allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'Text'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Maybe Text) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhString !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args kwargs')
                                       exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> allocEdhObj (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhString !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                         (ArgsPack args' kwargs')
                                         exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'Symbol'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg Symbol name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhSymbol !val' ->
          allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhSymbol !val' ->
            allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'Symbol'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Maybe Symbol) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhSymbol !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args kwargs')
                                       exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> allocEdhObj (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhSymbol !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                         (ArgsPack args' kwargs')
                                         exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'UUID'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg UUID.UUID name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhUUID !val' ->
          allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhUUID !val' ->
            allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'UUID'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Maybe UUID.UUID) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhUUID !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                     (ArgsPack args kwargs')
                                     exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> allocEdhObj (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhUUID !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args' kwargs')
                                       exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'EdhPair'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (EdhValue, EdhValue) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhPair !v1 !v2 ->
          allocEdhObj (fn (NamedEdhArg (v1, v2))) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhPair !v1 !v2 -> allocEdhObj (fn (NamedEdhArg (v1, v2)))
                                         (ArgsPack args' kwargs')
                                         exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'EdhPair'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Maybe (EdhValue, EdhValue)) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhPair !v1 !v2 -> allocEdhObj (fn (NamedEdhArg (Just (v1, v2))))
                                       (ArgsPack args kwargs')
                                       exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> allocEdhObj (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhPair !v1 !v2 -> allocEdhObj (fn (NamedEdhArg (Just (v1, v2))))
                                         (ArgsPack args' kwargs')
                                         exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'Dict'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg Dict name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhDict !val' ->
          allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhDict !val' ->
            allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'Dict'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Maybe Dict) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhDict !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                     (ArgsPack args kwargs')
                                     exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> allocEdhObj (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhDict !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args' kwargs')
                                       exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'List'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg List name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhList !val' ->
          allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhList !val' ->
            allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'List'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Maybe List) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhList !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                     (ArgsPack args kwargs')
                                     exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> allocEdhObj (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhList !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args' kwargs')
                                       exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'Object'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg Object name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhObject !val' ->
          allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhObject !val' ->
            allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'Object'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Maybe Object) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhObject !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args kwargs')
                                       exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> allocEdhObj (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhObject !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                         (ArgsPack args' kwargs')
                                         exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'Ordering'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg Ordering name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhOrd !val' ->
          allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhOrd !val' ->
            allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'Ordering'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Maybe Ordering) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhOrd !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                    (ArgsPack args kwargs')
                                    exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> allocEdhObj (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhOrd !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                      (ArgsPack args' kwargs')
                                      exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'EventSink'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg EventSink name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhSink !val' ->
          allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhSink !val' ->
            allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'EventSink'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Maybe EventSink) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhSink !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                     (ArgsPack args kwargs')
                                     exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> allocEdhObj (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhSink !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args' kwargs')
                                       exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'EdhNamedValue'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (AttrName,EdhValue) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhNamedValue !name !value -> allocEdhObj
          (fn (NamedEdhArg (name, value)))
          (ArgsPack args kwargs')
          exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhNamedValue !name !value -> allocEdhObj
            (fn (NamedEdhArg (name, value)))
            (ArgsPack args' kwargs')
            exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'EdhNamedValue'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Maybe (AttrName,EdhValue)) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhNamedValue !name !value -> allocEdhObj
          (fn (NamedEdhArg (Just (name, value))))
          (ArgsPack args kwargs')
          exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> allocEdhObj (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhNamedValue !name !value -> allocEdhObj
            (fn (NamedEdhArg (Just (name, value))))
            (ArgsPack args' kwargs')
            exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'EdhExpr'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Expr,Text) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhExpr _ !expr !src -> allocEdhObj (fn (NamedEdhArg (expr, src)))
                                            (ArgsPack args kwargs')
                                            exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhExpr _ !expr !src -> allocEdhObj (fn (NamedEdhArg (expr, src)))
                                              (ArgsPack args' kwargs')
                                              exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'EdhExpr'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Maybe (Expr,Text)) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhExpr _ !expr !src -> allocEdhObj
          (fn (NamedEdhArg (Just (expr, src))))
          (ArgsPack args kwargs')
          exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> allocEdhObj (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhExpr _ !expr !src -> allocEdhObj
            (fn (NamedEdhArg (Just (expr, src))))
            (ArgsPack args' kwargs')
            exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'ArgsPack'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg ArgsPack name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhArgsPack !val' ->
          allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhArgsPack !val' ->
            allocEdhObj (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'ArgsPack'
instance (KnownSymbol name, EdhAllocator fn') => EdhAllocator (NamedEdhArg (Maybe ArgsPack) name -> fn') where
  allocEdhObj !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhArgsPack !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                         (ArgsPack args kwargs')
                                         exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> allocEdhObj (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhArgsPack !val' -> allocEdhObj (fn (NamedEdhArg (Just val')))
                                           (ArgsPack args' kwargs')
                                           exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)


mkIntrinsicOp :: EdhWorld -> OpSymbol -> EdhIntrinsicOp -> STM EdhValue
mkIntrinsicOp !world !opSym !iop = do
  u <- unsafeIOToSTM newUnique
  Map.lookup opSym <$> readTMVar (edh'world'operators world) >>= \case
    Nothing ->
      throwSTM
        $ EdhError
            UsageError
            ("no precedence declared in the world for operator: " <> opSym)
            (toDyn nil)
        $ EdhCallContext "<edh>" []
    Just (preced, _) -> return
      $ EdhProcedure (EdhIntrOp preced $ IntrinOpDefi u opSym iop) Nothing


-- | Class for a procedure implemented in the host language (which is Haskell)
-- that can be called from Edh code.
--
-- Note the top frame of the call stack from thread state is the one for the
-- callee, that scope should have mounted the caller's scope entity, not a new
-- entity in contrast to when an Edh procedure as the callee.
class EdhCallable fn where
  callFromEdh :: fn -> ArgsPack -> EdhTxExit -> EdhTx


-- nullary base case
instance EdhCallable (EdhTxExit -> EdhTx) where
  callFromEdh !fn apk@(ArgsPack !args !kwargs) !exit =
    if null args && odNull kwargs
      then fn exit
      else \ !ets -> edhValueRepr ets (EdhArgsPack apk) $ \ !badRepr ->
        throwEdh ets UsageError $ "extraneous arguments: " <> badRepr

-- repack rest-positional-args
instance EdhCallable fn' => EdhCallable ([EdhValue] -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    callFromEdh (fn args) (ArgsPack [] kwargs) exit

-- repack rest-keyword-args
instance EdhCallable fn' => EdhCallable (OrderedDict AttrKey EdhValue -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    callFromEdh (fn kwargs) (ArgsPack args odEmpty) exit

-- repack rest-pack-args
-- note it'll cause runtime error if @fn'@ takes further args
instance EdhCallable fn' => EdhCallable (ArgsPack -> fn') where
  callFromEdh !fn !apk !exit = callFromEdh (fn apk) (ArgsPack [] odEmpty) exit

-- receive positional-only arg taking 'EdhValue'
instance EdhCallable fn' => EdhCallable (EdhValue -> fn') where
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit =
    callFromEdh (fn val) (ArgsPack args kwargs) exit
  callFromEdh _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'EdhValue'
instance EdhCallable fn' => EdhCallable (Maybe EdhValue -> fn') where
  callFromEdh !fn (ArgsPack [] !kwargs) !exit =
    callFromEdh (fn Nothing) (ArgsPack [] kwargs) exit
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit =
    callFromEdh (fn (Just val)) (ArgsPack args kwargs) exit

-- receive positional-only arg taking 'EdhTypeValue'
instance EdhCallable fn' => EdhCallable (EdhTypeValue -> fn') where
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhType !val' -> callFromEdh (fn val') (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"
  callFromEdh _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'EdhTypeValue'
instance EdhCallable fn' => EdhCallable (Maybe EdhTypeValue -> fn') where
  callFromEdh !fn (ArgsPack [] !kwargs) !exit =
    callFromEdh (fn Nothing) (ArgsPack [] kwargs) exit
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhType !val' -> callFromEdh (fn (Just val')) (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'Decimal'
instance EdhCallable fn' => EdhCallable (Decimal -> fn') where
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhDecimal !val' -> callFromEdh (fn val') (ArgsPack args kwargs) exit
    _                -> throwEdhTx UsageError "arg type mismatch: anonymous"
  callFromEdh _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'Decimal'
instance EdhCallable fn' => EdhCallable (Maybe Decimal -> fn') where
  callFromEdh !fn (ArgsPack [] !kwargs) !exit =
    callFromEdh (fn Nothing) (ArgsPack [] kwargs) exit
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhDecimal !val' ->
      callFromEdh (fn (Just val')) (ArgsPack args kwargs) exit
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'Integer'
instance EdhCallable fn' => EdhCallable (Integer -> fn') where
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhDecimal !val' -> case D.decimalToInteger val' of
      Just !i -> callFromEdh (fn i) (ArgsPack args kwargs) exit
      _       -> throwEdhTx UsageError "number type mismatch: anonymous"
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"
  callFromEdh _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'Integer'
instance EdhCallable fn' => EdhCallable (Maybe Integer -> fn') where
  callFromEdh !fn (ArgsPack [] !kwargs) !exit =
    callFromEdh (fn Nothing) (ArgsPack [] kwargs) exit
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhDecimal !val' -> case D.decimalToInteger val' of
      Just !i -> callFromEdh (fn (Just i)) (ArgsPack args kwargs) exit
      _       -> throwEdhTx UsageError "number type mismatch: anonymous"
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'Int'
instance EdhCallable fn' => EdhCallable (Int -> fn') where
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhDecimal !val' -> case D.decimalToInteger val' of
      Just !i -> callFromEdh (fn $ fromInteger i) (ArgsPack args kwargs) exit
      _       -> throwEdhTx UsageError "number type mismatch: anonymous"
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"
  callFromEdh _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'Int'
instance EdhCallable fn' => EdhCallable (Maybe Int -> fn') where
  callFromEdh !fn (ArgsPack [] !kwargs) !exit =
    callFromEdh (fn Nothing) (ArgsPack [] kwargs) exit
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhDecimal !val' -> case D.decimalToInteger val' of
      Just !i ->
        callFromEdh (fn (Just $ fromInteger i)) (ArgsPack args kwargs) exit
      _ -> throwEdhTx UsageError "number type mismatch: anonymous"
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'Bool'
instance EdhCallable fn' => EdhCallable (Bool -> fn') where
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhBool !val' -> callFromEdh (fn val') (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"
  callFromEdh _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'Bool'
instance EdhCallable fn' => EdhCallable (Maybe Bool -> fn') where
  callFromEdh !fn (ArgsPack [] !kwargs) !exit =
    callFromEdh (fn Nothing) (ArgsPack [] kwargs) exit
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhBool !val' -> callFromEdh (fn (Just val')) (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'Blob'
instance EdhCallable fn' => EdhCallable (ByteString -> fn') where
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhBlob !val' -> callFromEdh (fn val') (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"
  callFromEdh _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'Blob'
instance EdhCallable fn' => EdhCallable (Maybe ByteString -> fn') where
  callFromEdh !fn (ArgsPack [] !kwargs) !exit =
    callFromEdh (fn Nothing) (ArgsPack [] kwargs) exit
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhBlob !val' -> callFromEdh (fn (Just val')) (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'Text'
instance EdhCallable fn' => EdhCallable (Text -> fn') where
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhString !val' -> callFromEdh (fn val') (ArgsPack args kwargs) exit
    _               -> throwEdhTx UsageError "arg type mismatch: anonymous"
  callFromEdh _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'Text'
instance EdhCallable fn' => EdhCallable (Maybe Text -> fn') where
  callFromEdh !fn (ArgsPack [] !kwargs) !exit =
    callFromEdh (fn Nothing) (ArgsPack [] kwargs) exit
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhString !val' -> callFromEdh (fn (Just val')) (ArgsPack args kwargs) exit
    _               -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'Symbol'
instance EdhCallable fn' => EdhCallable (Symbol -> fn') where
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhSymbol !val' -> callFromEdh (fn val') (ArgsPack args kwargs) exit
    _               -> throwEdhTx UsageError "arg type mismatch: anonymous"
  callFromEdh _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'Symbol'
instance EdhCallable fn' => EdhCallable (Maybe Symbol -> fn') where
  callFromEdh !fn (ArgsPack [] !kwargs) !exit =
    callFromEdh (fn Nothing) (ArgsPack [] kwargs) exit
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhSymbol !val' -> callFromEdh (fn (Just val')) (ArgsPack args kwargs) exit
    _               -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'UUID'
instance EdhCallable fn' => EdhCallable (UUID.UUID -> fn') where
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhUUID !val' -> callFromEdh (fn val') (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"
  callFromEdh _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'UUID'
instance EdhCallable fn' => EdhCallable (Maybe UUID.UUID -> fn') where
  callFromEdh !fn (ArgsPack [] !kwargs) !exit =
    callFromEdh (fn Nothing) (ArgsPack [] kwargs) exit
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhUUID !val' -> callFromEdh (fn (Just val')) (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'EdhPair'
instance EdhCallable fn' => EdhCallable ((EdhValue, EdhValue) -> fn') where
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhPair !v1 !v2 -> callFromEdh (fn (v1, v2)) (ArgsPack args kwargs) exit
    _               -> throwEdhTx UsageError "arg type mismatch: anonymous"
  callFromEdh _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'EdhPair'
instance EdhCallable fn' => EdhCallable (Maybe (EdhValue, EdhValue) -> fn') where
  callFromEdh !fn (ArgsPack [] !kwargs) !exit =
    callFromEdh (fn Nothing) (ArgsPack [] kwargs) exit
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhPair !v1 !v2 ->
      callFromEdh (fn (Just (v1, v2))) (ArgsPack args kwargs) exit
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'Dict'
instance EdhCallable fn' => EdhCallable (Dict -> fn') where
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhDict !val' -> callFromEdh (fn val') (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"
  callFromEdh _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'Dict'
instance EdhCallable fn' => EdhCallable (Maybe Dict -> fn') where
  callFromEdh !fn (ArgsPack [] !kwargs) !exit =
    callFromEdh (fn Nothing) (ArgsPack [] kwargs) exit
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhDict !val' -> callFromEdh (fn (Just val')) (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'List'
instance EdhCallable fn' => EdhCallable (List -> fn') where
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhList !val' -> callFromEdh (fn val') (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"
  callFromEdh _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'List'
instance EdhCallable fn' => EdhCallable (Maybe List -> fn') where
  callFromEdh !fn (ArgsPack [] !kwargs) !exit =
    callFromEdh (fn Nothing) (ArgsPack [] kwargs) exit
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhList !val' -> callFromEdh (fn (Just val')) (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'Object'
instance EdhCallable fn' => EdhCallable (Object -> fn') where
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhObject !val' -> callFromEdh (fn val') (ArgsPack args kwargs) exit
    _               -> throwEdhTx UsageError "arg type mismatch: anonymous"
  callFromEdh _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'Object'
instance EdhCallable fn' => EdhCallable (Maybe Object -> fn') where
  callFromEdh !fn (ArgsPack [] !kwargs) !exit =
    callFromEdh (fn Nothing) (ArgsPack [] kwargs) exit
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhObject !val' -> callFromEdh (fn (Just val')) (ArgsPack args kwargs) exit
    _               -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'EdhOrd'
instance EdhCallable fn' => EdhCallable (Ordering -> fn') where
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhOrd !val' -> callFromEdh (fn val') (ArgsPack args kwargs) exit
    _            -> throwEdhTx UsageError "arg type mismatch: anonymous"
  callFromEdh _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'EdhOrd'
instance EdhCallable fn' => EdhCallable (Maybe Ordering -> fn') where
  callFromEdh !fn (ArgsPack [] !kwargs) !exit =
    callFromEdh (fn Nothing) (ArgsPack [] kwargs) exit
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhOrd !val' -> callFromEdh (fn (Just val')) (ArgsPack args kwargs) exit
    _            -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'EventSink'
instance EdhCallable fn' => EdhCallable (EventSink -> fn') where
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhSink !val' -> callFromEdh (fn val') (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"
  callFromEdh _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'EventSink'
instance EdhCallable fn' => EdhCallable (Maybe EventSink -> fn') where
  callFromEdh !fn (ArgsPack [] !kwargs) !exit =
    callFromEdh (fn Nothing) (ArgsPack [] kwargs) exit
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhSink !val' -> callFromEdh (fn (Just val')) (ArgsPack args kwargs) exit
    _             -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'EdhNamedValue'
instance EdhCallable fn' => EdhCallable ((AttrName,EdhValue) -> fn') where
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhNamedValue !name !value ->
      callFromEdh (fn (name, value)) (ArgsPack args kwargs) exit
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"
  callFromEdh _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'EdhNamedValue'
instance EdhCallable fn' => EdhCallable (Maybe (AttrName,EdhValue) -> fn') where
  callFromEdh !fn (ArgsPack [] !kwargs) !exit =
    callFromEdh (fn Nothing) (ArgsPack [] kwargs) exit
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhNamedValue !name !value ->
      callFromEdh (fn (Just (name, value))) (ArgsPack args kwargs) exit
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"

-- receive positional-only arg taking 'EdhExpr'
instance EdhCallable fn' => EdhCallable ((Expr,Text) -> fn') where
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhExpr _ !expr !src ->
      callFromEdh (fn (expr, src)) (ArgsPack args kwargs) exit
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"
  callFromEdh _ _ _ = throwEdhTx UsageError "missing anonymous arg"

-- receive positional-only, optional arg taking 'EdhExpr'
instance EdhCallable fn' => EdhCallable (Maybe (Expr,Text) -> fn') where
  callFromEdh !fn (ArgsPack [] !kwargs) !exit =
    callFromEdh (fn Nothing) (ArgsPack [] kwargs) exit
  callFromEdh !fn (ArgsPack (val : args) !kwargs) !exit = case val of
    EdhExpr _ !expr !src ->
      callFromEdh (fn (Just (expr, src))) (ArgsPack args kwargs) exit
    _ -> throwEdhTx UsageError "arg type mismatch: anonymous"


-- receive named arg taking 'EdhValue'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg EdhValue name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, kwargs') ->
        callFromEdh (fn (NamedEdhArg val)) (ArgsPack args kwargs') exit
      (Nothing, kwargs') -> case args of
        [] -> throwEdhTx UsageError $ "missing named arg: " <> argName
        (val : args') ->
          callFromEdh (fn (NamedEdhArg val)) (ArgsPack args' kwargs') exit
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'EdhValue'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Maybe EdhValue) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Nothing, !kwargs') -> case args of
        [] -> callFromEdh (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> callFromEdh (fn (NamedEdhArg (Just val)))
                                   (ArgsPack args' kwargs')
                                   exit
      (!maybeVal, !kwargs') ->
        callFromEdh (fn (NamedEdhArg maybeVal)) (ArgsPack args kwargs') exit
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'EdhTypeValue'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg EdhTypeValue name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhType !val' ->
          callFromEdh (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhType !val' ->
            callFromEdh (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'EdhTypeValue'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Maybe EdhTypeValue) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhType !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                     (ArgsPack args kwargs')
                                     exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> callFromEdh (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhType !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args' kwargs')
                                       exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'Decimal'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg Decimal name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhDecimal !val' ->
          callFromEdh (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhDecimal !val' ->
            callFromEdh (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'Decimal'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Maybe Decimal) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhDecimal !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                        (ArgsPack args kwargs')
                                        exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> callFromEdh (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhDecimal !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                          (ArgsPack args' kwargs')
                                          exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'Integer'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg Integer name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhDecimal !val' -> case D.decimalToInteger val' of
          Just !i ->
            callFromEdh (fn (NamedEdhArg i)) (ArgsPack args kwargs') exit
          _ -> throwEdhTx UsageError $ "number type mismatch: " <> argName
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhDecimal !val' -> case D.decimalToInteger val' of
            Just !i ->
              callFromEdh (fn (NamedEdhArg i)) (ArgsPack args' kwargs') exit
            _ -> throwEdhTx UsageError $ "number type mismatch: " <> argName
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'Integer'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Maybe Integer) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhDecimal !val' -> case D.decimalToInteger val' of
          Just !i ->
            callFromEdh (fn (NamedEdhArg (Just i))) (ArgsPack args kwargs') exit
          _ -> throwEdhTx UsageError $ "number type mismatch: " <> argName
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> callFromEdh (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhDecimal !val' -> case D.decimalToInteger val' of
            Just !i -> callFromEdh (fn (NamedEdhArg (Just i)))
                                   (ArgsPack args' kwargs')
                                   exit
            _ -> throwEdhTx UsageError $ "number type mismatch: " <> argName
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'Int'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg Int name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhDecimal !val' -> case D.decimalToInteger val' of
          Just !i -> callFromEdh (fn (NamedEdhArg $ fromInteger i))
                                 (ArgsPack args kwargs')
                                 exit
          _ -> throwEdhTx UsageError $ "number type mismatch: " <> argName
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhDecimal !val' -> case D.decimalToInteger val' of
            Just !i -> callFromEdh (fn (NamedEdhArg $ fromInteger i))
                                   (ArgsPack args' kwargs')
                                   exit
            _ -> throwEdhTx UsageError $ "number type mismatch: " <> argName
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'Int'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Maybe Int) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhDecimal !val' -> case D.decimalToInteger val' of
          Just !i -> callFromEdh (fn (NamedEdhArg (Just $ fromInteger i)))
                                 (ArgsPack args kwargs')
                                 exit
          _ -> throwEdhTx UsageError $ "number type mismatch: " <> argName
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> callFromEdh (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhDecimal !val' -> case D.decimalToInteger val' of
            Just !i -> callFromEdh (fn (NamedEdhArg (Just $ fromInteger i)))
                                   (ArgsPack args' kwargs')
                                   exit
            _ -> throwEdhTx UsageError $ "number type mismatch: " <> argName
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'Bool'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg Bool name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhBool !val' ->
          callFromEdh (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhBool !val' ->
            callFromEdh (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'Bool'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Maybe Bool) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhBool !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                     (ArgsPack args kwargs')
                                     exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> callFromEdh (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhBool !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args' kwargs')
                                       exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'ByteString'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg ByteString name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhBlob !val' ->
          callFromEdh (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhBlob !val' ->
            callFromEdh (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'ByteString'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Maybe ByteString) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhBlob !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                     (ArgsPack args kwargs')
                                     exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> callFromEdh (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhBlob !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args' kwargs')
                                       exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'Text'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg Text name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhString !val' ->
          callFromEdh (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhString !val' ->
            callFromEdh (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'Text'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Maybe Text) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhString !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args kwargs')
                                       exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> callFromEdh (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhString !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                         (ArgsPack args' kwargs')
                                         exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'Symbol'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg Symbol name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhSymbol !val' ->
          callFromEdh (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhSymbol !val' ->
            callFromEdh (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'Symbol'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Maybe Symbol) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhSymbol !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args kwargs')
                                       exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> callFromEdh (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhSymbol !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                         (ArgsPack args' kwargs')
                                         exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'UUID'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg UUID.UUID name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhUUID !val' ->
          callFromEdh (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhUUID !val' ->
            callFromEdh (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'UUID'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Maybe UUID.UUID) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhUUID !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                     (ArgsPack args kwargs')
                                     exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> callFromEdh (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhUUID !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args' kwargs')
                                       exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'EdhPair'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (EdhValue, EdhValue) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhPair !v1 !v2 ->
          callFromEdh (fn (NamedEdhArg (v1, v2))) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhPair !v1 !v2 -> callFromEdh (fn (NamedEdhArg (v1, v2)))
                                         (ArgsPack args' kwargs')
                                         exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'EdhPair'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Maybe (EdhValue, EdhValue)) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhPair !v1 !v2 -> callFromEdh (fn (NamedEdhArg (Just (v1, v2))))
                                       (ArgsPack args kwargs')
                                       exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> callFromEdh (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhPair !v1 !v2 -> callFromEdh (fn (NamedEdhArg (Just (v1, v2))))
                                         (ArgsPack args' kwargs')
                                         exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'Dict'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg Dict name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhDict !val' ->
          callFromEdh (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhDict !val' ->
            callFromEdh (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'Dict'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Maybe Dict) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhDict !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                     (ArgsPack args kwargs')
                                     exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> callFromEdh (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhDict !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args' kwargs')
                                       exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'List'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg List name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhList !val' ->
          callFromEdh (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhList !val' ->
            callFromEdh (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'List'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Maybe List) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhList !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                     (ArgsPack args kwargs')
                                     exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> callFromEdh (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhList !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args' kwargs')
                                       exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'Object'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg Object name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhObject !val' ->
          callFromEdh (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhObject !val' ->
            callFromEdh (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'Object'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Maybe Object) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhObject !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args kwargs')
                                       exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> callFromEdh (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhObject !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                         (ArgsPack args' kwargs')
                                         exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'Ordering'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg Ordering name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhOrd !val' ->
          callFromEdh (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhOrd !val' ->
            callFromEdh (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'Ordering'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Maybe Ordering) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhOrd !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                    (ArgsPack args kwargs')
                                    exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> callFromEdh (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhOrd !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                      (ArgsPack args' kwargs')
                                      exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'EventSink'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg EventSink name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhSink !val' ->
          callFromEdh (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhSink !val' ->
            callFromEdh (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'EventSink'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Maybe EventSink) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhSink !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                     (ArgsPack args kwargs')
                                     exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> callFromEdh (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhSink !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                       (ArgsPack args' kwargs')
                                       exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'EdhNamedValue'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (AttrName,EdhValue) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhNamedValue !name !value -> callFromEdh
          (fn (NamedEdhArg (name, value)))
          (ArgsPack args kwargs')
          exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhNamedValue !name !value -> callFromEdh
            (fn (NamedEdhArg (name, value)))
            (ArgsPack args' kwargs')
            exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'EdhNamedValue'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Maybe (AttrName,EdhValue)) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhNamedValue !name !value -> callFromEdh
          (fn (NamedEdhArg (Just (name, value))))
          (ArgsPack args kwargs')
          exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> callFromEdh (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhNamedValue !name !value -> callFromEdh
            (fn (NamedEdhArg (Just (name, value))))
            (ArgsPack args' kwargs')
            exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'EdhExpr'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Expr,Text) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhExpr _ !expr !src -> callFromEdh (fn (NamedEdhArg (expr, src)))
                                            (ArgsPack args kwargs')
                                            exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhExpr _ !expr !src -> callFromEdh (fn (NamedEdhArg (expr, src)))
                                              (ArgsPack args' kwargs')
                                              exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'EdhExpr'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Maybe (Expr,Text)) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhExpr _ !expr !src -> callFromEdh
          (fn (NamedEdhArg (Just (expr, src))))
          (ArgsPack args kwargs')
          exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> callFromEdh (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhExpr _ !expr !src -> callFromEdh
            (fn (NamedEdhArg (Just (expr, src))))
            (ArgsPack args' kwargs')
            exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named arg taking 'ArgsPack'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg ArgsPack name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhArgsPack !val' ->
          callFromEdh (fn (NamedEdhArg val')) (ArgsPack args kwargs') exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        []          -> throwEdhTx UsageError $ "missing named arg: " <> argName
        val : args' -> case val of
          EdhArgsPack !val' ->
            callFromEdh (fn (NamedEdhArg val')) (ArgsPack args' kwargs') exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)

-- receive named, optional arg taking 'ArgsPack'
instance (KnownSymbol name, EdhCallable fn') => EdhCallable (NamedEdhArg (Maybe ArgsPack) name -> fn') where
  callFromEdh !fn (ArgsPack !args !kwargs) !exit =
    case odTakeOut (AttrByName argName) kwargs of
      (Just !val, !kwargs') -> case val of
        EdhArgsPack !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                         (ArgsPack args kwargs')
                                         exit
        _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
      (Nothing, !kwargs') -> case args of
        [] -> callFromEdh (fn (NamedEdhArg Nothing)) (ArgsPack [] kwargs') exit
        val : args' -> case val of
          EdhArgsPack !val' -> callFromEdh (fn (NamedEdhArg (Just val')))
                                           (ArgsPack args' kwargs')
                                           exit
          _ -> throwEdhTx UsageError $ "arg type mismatch: " <> argName
    where !argName = T.pack $ symbolVal (Proxy :: Proxy name)


wrapHostProc :: EdhCallable fn => fn -> (ArgsPack -> EdhHostProc, ArgsReceiver)
wrapHostProc !fn = -- TODO derive arg receivers (procedure signature)
  (callFromEdh fn, WildReceiver)


mkHostProc
  :: Scope
  -> (ProcDefi -> EdhProc)
  -> AttrName
  -> (ArgsPack -> EdhHostProc, ArgsReceiver)
  -> STM EdhValue
mkHostProc !scope !vc !nm (!p, !args) = do
  !u <- unsafeIOToSTM newUnique
  return $ EdhProcedure
    (vc ProcDefi
      { edh'procedure'ident = u
      , edh'procedure'name  = AttrByName nm
      , edh'procedure'lexi  = scope
      , edh'procedure'decl  = ProcDecl { edh'procedure'addr = NamedAttr nm
                                       , edh'procedure'args = args
                                       , edh'procedure'body = Right p
                                       }
      }
    )
    Nothing
mkHostProc'
  :: EdhCallable fn
  => Scope
  -> (ProcDefi -> EdhProc)
  -> AttrName
  -> fn
  -> STM EdhValue
mkHostProc' !scope !vc !nm !fn = mkHostProc scope vc nm $ wrapHostProc fn


mkSymbolicHostProc
  :: Scope
  -> (ProcDefi -> EdhProc)
  -> Symbol
  -> (ArgsPack -> EdhHostProc, ArgsReceiver)
  -> STM EdhValue
mkSymbolicHostProc !scope !vc !sym (!p, !args) = do
  !u <- unsafeIOToSTM newUnique
  return $ EdhProcedure
    (vc ProcDefi
      { edh'procedure'ident = u
      , edh'procedure'name  = AttrBySym sym
      , edh'procedure'lexi  = scope
      , edh'procedure'decl  = ProcDecl
                                { edh'procedure'addr = SymbolicAttr
                                                         $ symbolName sym
                                , edh'procedure'args = args
                                , edh'procedure'body = Right $ callFromEdh p
                                }
      }
    )
    Nothing
mkSymbolicHostProc'
  :: EdhCallable fn
  => Scope
  -> (ProcDefi -> EdhProc)
  -> Symbol
  -> fn
  -> STM EdhValue
mkSymbolicHostProc' !scope !vc !sym !fn =
  mkSymbolicHostProc scope vc sym $ wrapHostProc fn


mkHostProperty
  :: Scope
  -> AttrName
  -> EdhHostProc
  -> Maybe (Maybe EdhValue -> EdhHostProc)
  -> STM EdhValue
mkHostProperty !scope !nm !getterProc !maybeSetterProc = do
  getter <- do
    u <- unsafeIOToSTM newUnique
    return $ ProcDefi
      { edh'procedure'ident = u
      , edh'procedure'name  = AttrByName nm
      , edh'procedure'lexi  = scope
      , edh'procedure'decl  = ProcDecl
        { edh'procedure'addr = NamedAttr nm
        , edh'procedure'args = PackReceiver []
        , edh'procedure'body = Right $ callFromEdh getterProc
        }
      }
  setter <- case maybeSetterProc of
    Nothing          -> return Nothing
    Just !setterProc -> do
      u <- unsafeIOToSTM newUnique
      return $ Just $ ProcDefi
        { edh'procedure'ident = u
        , edh'procedure'name  = AttrByName nm
        , edh'procedure'lexi  = scope
        , edh'procedure'decl  = ProcDecl
          { edh'procedure'addr = NamedAttr nm
          , edh'procedure'args = PackReceiver
            [ RecvArg (NamedAttr "newValue") Nothing
              $ Just
              $ LitExpr
              $ ValueLiteral edhNone
            ]
          , edh'procedure'body = Right $ callFromEdh setterProc
          }
        }
  return $ EdhProcedure (EdhDescriptor getter setter) Nothing

