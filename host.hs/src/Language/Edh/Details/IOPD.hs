
module Language.Edh.Details.IOPD where

import           Prelude
-- import           Debug.Trace

import           Control.Monad.ST

import           Control.Concurrent.STM

import           Data.Hashable
import qualified Data.HashMap.Strict           as Map
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as V
import qualified Data.Vector.Mutable           as MV


-- | Mutable dict with insertion order preserved
-- (Insertion Order Preserving Dict)
--
-- An iopd can only be mutated through STM monad, conflicts wrt concurrent
-- modifications are resolved automatically by STM retry
data IOPD k v where
  IOPD ::(Eq k, Hashable k) =>  {
      iopd'map :: {-# UNPACK #-} !(TVar (Map.HashMap k Int))
    , iopd'write'pos :: {-# UNPACK #-} !(TVar Int)
    , iopd'num'holes :: {-# UNPACK #-} !(TVar Int)
    -- TODO will the Vector possibly crash the program?
    -- https://mail.haskell.org/pipermail/glasgow-haskell-users/2020-August/026947.html
    , iopd'array :: {-# UNPACK #-} !(TVar (Vector (TVar (Maybe (k, v)))))
    } -> IOPD k v

iopdClone :: forall k v . (Eq k, Hashable k) => IOPD k v -> STM (IOPD k v)
iopdClone (IOPD !mv !wpv !nhv !av) = do
  !mv'  <- newTVar =<< readTVar mv
  !wpv' <- newTVar =<< readTVar wpv
  !nhv' <- newTVar =<< readTVar nhv
  !av'  <- newTVar =<< do
    !a <- readTVar av
    let a' = runST $ V.thaw a >>= V.freeze
    return a'
  return $ IOPD mv' wpv' nhv' av'

iopdTransform
  :: forall k v v'
   . (Eq k, Hashable k)
  => (v -> v')
  -> IOPD k v
  -> STM (IOPD k v')
iopdTransform !trans (IOPD !mv !wpv !nhv !av) = do
  !mv'  <- newTVar =<< readTVar mv
  !wpv' <- newTVar =<< readTVar wpv
  !nhv' <- newTVar =<< readTVar nhv
  !av'  <- newTVar =<< do
    !a  <- readTVar av
    !a' <- flip V.mapM a $ \ !ev -> readTVar ev >>= \case
      Nothing       -> newTVar Nothing
      Just (!k, !v) -> newTVar $ Just (k, trans v)
    let a'' = runST $ V.thaw a' >>= V.freeze
    return a''
  return $ IOPD mv' wpv' nhv' av'

iopdEmpty :: forall k v . (Eq k, Hashable k) => STM (IOPD k v)
iopdEmpty = do
  !mv  <- newTVar Map.empty
  !wpv <- newTVar 0
  !nhv <- newTVar 0
  !av  <- newTVar V.empty
  return $ IOPD mv wpv nhv av

iopdNull :: forall k v . (Eq k, Hashable k) => IOPD k v -> STM Bool
iopdNull (IOPD _mv !wpv !nhv _av) = do
  !wp <- readTVar wpv
  !nh <- readTVar nhv
  return (wp - nh <= 0)

iopdSize :: forall k v . (Eq k, Hashable k) => IOPD k v -> STM Int
iopdSize (IOPD _mv !wpv !nhv _av) = do
  !wp <- readTVar wpv
  !nh <- readTVar nhv
  return $ wp - nh

iopdSingleton :: forall k v . (Eq k, Hashable k) => k -> v -> STM (IOPD k v)
iopdSingleton !key !val = do
  !mv  <- newTVar $ Map.singleton key 0
  !wpv <- newTVar 1
  !nhv <- newTVar 0
  !av  <- newTVar . V.singleton =<< newTVar (Just (key, val))
  return $ IOPD mv wpv nhv av

iopdInsert :: forall k v . (Eq k, Hashable k) => k -> v -> IOPD k v -> STM ()
iopdInsert !key !val d@(IOPD !mv !wpv _nhv !av) =
  Map.lookup key <$> readTVar mv >>= \case
    Just !i ->
      flip V.unsafeIndex i <$> readTVar av >>= flip writeTVar (Just (key, val))
    Nothing -> do
      !entry <- newTVar $ Just (key, val)
      !wp0   <- readTVar wpv
      !a0    <- readTVar av
      if wp0 >= V.length a0 then iopdReserve 7 d else pure ()
      !wp <- readTVar wpv
      !a  <- readTVar av
      if wp >= V.length a
        then error "bug: iopd reservation malfunctioned"
        else pure ()
      flip seq (modifyTVar' mv $ Map.insert key wp) $ runST $ do
        !a' <- V.unsafeThaw a
        MV.unsafeWrite a' wp entry
      writeTVar wpv (wp + 1)

iopdReserve :: forall k v . (Eq k, Hashable k) => Int -> IOPD k v -> STM ()
iopdReserve !moreCap (IOPD _mv !wpv _nhv !av) = do
  !wp <- readTVar wpv
  !a  <- readTVar av
  let !needCap = wp + moreCap
      !cap     = V.length a
  if cap >= needCap
    then return ()
    else do
      let !aNew = runST $ do
            !a' <- MV.unsafeNew needCap
            MV.unsafeCopy (MV.unsafeSlice 0 wp a')
              =<< V.unsafeThaw (V.slice 0 wp a)
            V.unsafeFreeze a'
      writeTVar av aNew

iopdUpdate :: forall k v . (Eq k, Hashable k) => [(k, v)] -> IOPD k v -> STM ()
iopdUpdate !ps !d = if null ps
  then return ()
  else do
    iopdReserve (length ps) d
    upd ps
 where
  upd []                    = return ()
  upd ((!key, !val) : rest) = do
    iopdInsert key val d
    upd rest

iopdLookup :: forall k v . (Eq k, Hashable k) => k -> IOPD k v -> STM (Maybe v)
iopdLookup !key (IOPD !mv _wpv _nhv !av) =
  Map.lookup key <$> readTVar mv >>= \case
    Nothing -> return Nothing
    Just !i ->
      (fmap snd <$>) $ flip V.unsafeIndex i <$> readTVar av >>= readTVar

iopdLookupDefault
  :: forall k v . (Eq k, Hashable k) => v -> k -> IOPD k v -> STM v
iopdLookupDefault !defaultVal !key !iopd = iopdLookup key iopd >>= \case
  Nothing   -> return defaultVal
  Just !val -> return val

iopdDelete :: forall k v . (Eq k, Hashable k) => k -> IOPD k v -> STM ()
iopdDelete !key (IOPD !mv _wpv !nhv !av) =
  Map.lookup key <$> readTVar mv >>= \case
    Nothing -> return ()
    Just !i -> do
      flip V.unsafeIndex i <$> readTVar av >>= flip writeTVar Nothing
      modifyTVar' nhv (+ 1)

iopdKeys :: forall k v . (Eq k, Hashable k) => IOPD k v -> STM [k]
iopdKeys (IOPD _mv !wpv _nhv !av) = do
  !wp <- readTVar wpv
  !a  <- readTVar av
  let go !keys !i | i < 0 = return keys
      go !keys !i         = readTVar (V.unsafeIndex a i) >>= \case
        Nothing           -> go keys (i - 1)
        Just (!key, _val) -> go (key : keys) (i - 1)
  go [] (wp - 1)

iopdValues :: forall k v . (Eq k, Hashable k) => IOPD k v -> STM [v]
iopdValues (IOPD _mv !wpv _nhv !av) = do
  !wp <- readTVar wpv
  !a  <- readTVar av
  let go !vals !i | i < 0 = return vals
      go !vals !i         = readTVar (V.unsafeIndex a i) >>= \case
        Nothing           -> go vals (i - 1)
        Just (_key, !val) -> go (val : vals) (i - 1)
  go [] (wp - 1)

iopdToList :: forall k v . (Eq k, Hashable k) => IOPD k v -> STM [(k, v)]
iopdToList (IOPD _mv !wpv _nhv !av) = do
  !wp <- readTVar wpv
  !a  <- readTVar av
  let go !entries !i | i < 0 = return entries
      go !entries !i         = readTVar (V.unsafeIndex a i) >>= \case
        Nothing     -> go entries (i - 1)
        Just !entry -> go (entry : entries) (i - 1)
  go [] (wp - 1)

iopdToReverseList
  :: forall k v . (Eq k, Hashable k) => IOPD k v -> STM [(k, v)]
iopdToReverseList (IOPD _mv !wpv _nhv !av) = do
  !wp <- readTVar wpv
  !a  <- readTVar av
  let go !entries !i | i >= wp = return entries
      go !entries !i           = readTVar (V.unsafeIndex a i) >>= \case
        Nothing     -> go entries (i + 1)
        Just !entry -> go (entry : entries) (i + 1)
  go [] 0

iopdFromList :: forall k v . (Eq k, Hashable k) => [(k, v)] -> STM (IOPD k v)
iopdFromList !entries = do
  !tves <- sequence $ [ (key, ) <$> newTVar (Just e) | e@(!key, _) <- entries ]
  let (mNew, wpNew, nhNew, aNew) = runST $ do
        !a <- MV.unsafeNew cap
        let go [] !m !wp !nh = (m, wp, nh, ) <$> V.unsafeFreeze a
            go ((!key, !ev) : rest) !m !wp !nh = case Map.lookup key m of
              Nothing -> do
                MV.unsafeWrite a wp ev
                go rest (Map.insert key wp m) (wp + 1) nh
              Just !i -> do
                MV.unsafeWrite a i ev
                go rest m wp nh
        go tves Map.empty 0 0
  !mv  <- newTVar mNew
  !wpv <- newTVar wpNew
  !nhv <- newTVar nhNew
  !av  <- newTVar aNew
  return $ IOPD mv wpv nhv av
  where cap = length entries



iopdSnapshot
  :: forall k v . (Eq k, Hashable k) => IOPD k v -> STM (OrderedDict k v)
iopdSnapshot (IOPD !mv !wpv _nhv !av) = do
  !m  <- readTVar mv
  !wp <- readTVar wpv
  !a  <- readTVar av
  !a' <- V.sequence (readTVar <$> V.slice 0 wp a)
  return $ OrderedDict m a'


-- | Immutable dict with insertion order preserved
--
-- can be created either by 'odFromList', or taken as a snapshot of an IOPD
data OrderedDict k v where
  OrderedDict ::(Eq k, Hashable k) => {
      od'map :: !(Map.HashMap k Int)
    , od'array :: !(Vector (Maybe (k, v)))
    } -> OrderedDict k v
instance (Eq k, Hashable k, Eq v, Hashable v) => Eq (OrderedDict k v) where
  x == y = odToList x == odToList y
instance (Eq k, Hashable k, Eq v, Hashable v) => Hashable (OrderedDict k v) where
  hashWithSalt s od@(OrderedDict m _a) =
    s `hashWithSalt` m `hashWithSalt` odToList od

odTransform
  :: forall k v v'
   . (Eq k, Hashable k)
  => (v -> v')
  -> OrderedDict k v
  -> OrderedDict k v'
odTransform !trans (OrderedDict !m !a) =
  OrderedDict m $ flip V.map a $ fmap $ \(!k, !v) -> (k, trans v)

odEmpty :: forall k v . (Eq k, Hashable k) => OrderedDict k v
odEmpty = OrderedDict Map.empty V.empty

odNull :: forall k v . (Eq k, Hashable k) => OrderedDict k v -> Bool
odNull (OrderedDict !m _a) = Map.null m

odSize :: forall k v . (Eq k, Hashable k) => OrderedDict k v -> Int
odSize (OrderedDict !m _a) = Map.size m

odLookup :: forall k v . (Eq k, Hashable k) => k -> OrderedDict k v -> Maybe v
odLookup !key (OrderedDict !m !a) = case Map.lookup key m of
  Nothing -> Nothing
  Just !i -> snd <$> V.unsafeIndex a i

odLookupDefault
  :: forall k v . (Eq k, Hashable k) => v -> k -> OrderedDict k v -> v
odLookupDefault !defaultVal !key !d = case odLookup key d of
  Nothing   -> defaultVal
  Just !val -> val

odLookupDefault'
  :: forall k v v'
   . (Eq k, Hashable k)
  => v'
  -> (v -> v')
  -> k
  -> OrderedDict k v
  -> v'
odLookupDefault' !defaultVal !f !key !d = case odLookup key d of
  Nothing   -> defaultVal
  Just !val -> f val

odLookupContSTM
  :: forall k v v'
   . (Eq k, Hashable k)
  => v'
  -> (v -> (v' -> STM ()) -> STM ())
  -> k
  -> OrderedDict k v
  -> (v' -> STM ())
  -> STM ()
odLookupContSTM !defaultVal !f !key !d !exit = case odLookup key d of
  Nothing   -> exit defaultVal
  Just !val -> f val exit

odTakeOut
  :: forall k v
   . (Eq k, Hashable k)
  => k
  -> OrderedDict k v
  -> (Maybe v, OrderedDict k v)
odTakeOut !key od@(OrderedDict !m !a) = case Map.lookup key m of
  Nothing -> (Nothing, od)
  Just !i -> (snd <$> V.unsafeIndex a i, OrderedDict (Map.delete key m) a)

odKeys :: forall k v . (Eq k, Hashable k) => OrderedDict k v -> [k]
odKeys (OrderedDict !m _a) = Map.keys m

odValues :: forall k v . (Eq k, Hashable k) => OrderedDict k v -> [v]
odValues (OrderedDict _m !a) = go [] (V.length a - 1)
 where
  go :: [v] -> Int -> [v]
  go !vals !i | i < 0 = vals
  go !vals !i         = case V.unsafeIndex a i of
    Nothing           -> go vals (i - 1)
    Just (_key, !val) -> go (val : vals) (i - 1)

odToList :: forall k v . (Eq k, Hashable k) => OrderedDict k v -> [(k, v)]
odToList (OrderedDict !m !a) = go [] (V.length a - 1)
 where
  go :: [(k, v)] -> Int -> [(k, v)]
  go !entries !i | i < 0 = entries
  go !entries !i         = case V.unsafeIndex a i of
    Nothing                -> go entries (i - 1)
    Just entry@(key, _val) -> if Map.member key m
      then go (entry : entries) (i - 1)
      else go entries (i - 1)

odToReverseList
  :: forall k v . (Eq k, Hashable k) => OrderedDict k v -> [(k, v)]
odToReverseList (OrderedDict !m !a) = go [] 0
 where
  !cap = V.length a
  go :: [(k, v)] -> Int -> [(k, v)]
  go !entries !i | i >= cap = entries
  go !entries !i            = case V.unsafeIndex a i of
    Nothing                -> go entries (i + 1)
    Just entry@(key, _val) -> if Map.member key m
      then go (entry : entries) (i + 1)
      else go entries (i + 1)

odFromList :: forall k v . (Eq k, Hashable k) => [(k, v)] -> OrderedDict k v
odFromList !entries =
  let (mNew, aNew) = runST $ do
        !a <- MV.unsafeNew $ length entries
        let go []                    !m _wp = (m, ) <$> V.unsafeFreeze a
            go (ev@(!key, _) : rest) !m !wp = case Map.lookup key m of
              Nothing -> do
                MV.unsafeWrite a wp $ Just ev
                go rest (Map.insert key wp m) (wp + 1)
              Just !i -> do
                MV.unsafeWrite a i $ Just ev
                go rest m wp
        go entries Map.empty 0
  in  OrderedDict mNew aNew

odMap
  :: forall k v v'
   . (Eq k, Hashable k)
  => (v -> v')
  -> OrderedDict k v
  -> OrderedDict k v'
odMap _f (OrderedDict !m _a) | Map.null m = OrderedDict Map.empty V.empty
odMap !f (OrderedDict !m !a) =
  let !aNew = runST $ do
        !a' <- MV.unsafeNew $ V.length a
        MV.set a' Nothing
        let go []                  = V.unsafeFreeze a'
            go ((!key, !i) : rest) = do
              case V.unsafeIndex a i of
                Just (_, !val) -> MV.unsafeWrite a' i $ Just (key, f val)
                Nothing        -> pure () -- should fail hard in this case?
              go rest
        go (Map.toList m)
  in  OrderedDict m aNew

odMapSTM
  :: forall k v v'
   . (Eq k, Hashable k)
  => (v -> STM v')
  -> OrderedDict k v
  -> STM (OrderedDict k v')
odMapSTM _f (OrderedDict !m _a) | Map.null m =
  return $ OrderedDict Map.empty V.empty
odMapSTM !f (OrderedDict !m !a) =
  let !aNew = runST $ do
        !a' <- MV.unsafeNew $ V.length a
        MV.set a' $ return Nothing
        let go []                  = V.unsafeFreeze a'
            go ((!key, !i) : rest) = do
              case V.unsafeIndex a i of
                Just (_, !val) ->
                  MV.unsafeWrite a' i $ Just . (key, ) <$> f val
                Nothing -> pure () -- should fail hard in this case?
              go rest
        go (Map.toList m)
  in  OrderedDict m <$> V.sequence aNew

odMapContSTM
  :: forall k v v'
   . (Eq k, Hashable k)
  => (v -> (v' -> STM ()) -> STM ())
  -> OrderedDict k v
  -> (OrderedDict k v' -> STM ())
  -> STM ()
odMapContSTM _f (OrderedDict !m _a) !exit | Map.null m =
  exit $ OrderedDict Map.empty V.empty
odMapContSTM !f (OrderedDict _m !a) !exit = toList (V.length a - 1) []
 where
  toList :: Int -> [(k, v')] -> STM ()
  toList !i !entries | i < 0 = exit $ odFromList entries
  toList !i !entries         = case V.unsafeIndex a i of
    Nothing -> toList (i - 1) entries
    Just (!key, !val) ->
      f val $ \ !val' -> toList (i - 1) $ (key, val') : entries

odMapContSTM'
  :: forall k v v'
   . (Eq k, Hashable k)
  => ((k, v) -> (v' -> STM ()) -> STM ())
  -> OrderedDict k v
  -> (OrderedDict k v' -> STM ())
  -> STM ()
odMapContSTM' _f (OrderedDict !m _a) !exit | Map.null m =
  exit $ OrderedDict Map.empty V.empty
odMapContSTM' !f (OrderedDict _m !a) !exit = toList (V.length a - 1) []
 where
  toList :: Int -> [(k, v')] -> STM ()
  toList !i !entries | i < 0 = exit $ odFromList entries
  toList !i !entries         = case V.unsafeIndex a i of
    Nothing -> toList (i - 1) entries
    Just (!key, !val) ->
      f (key, val) $ \ !val' -> toList (i - 1) $ (key, val') : entries

