
module Language.Edh.Event where

import           Prelude

import           Control.Monad

import           Control.Concurrent.STM

import           Language.Edh.Details.RtTypes


-- | create a new event sink
newEventSink :: STM EventSink
newEventSink = do
  seqn <- newTVar 0
  mrv  <- newTVar nil
  chan <- newBroadcastTChan
  subc <- newTVar 0
  return EventSink { evs'seqn = seqn
                   , evs'mrv  = mrv
                   , evs'chan = chan
                   , evs'subc = subc
                   }

-- | Subscribe to an event sink
--
-- A subscriber's channel for event reading, and the most recent event
-- value if available are returned
--
-- CAVEAT: should not by other means be dup'ing the broadcast channel,
--         to obtain a subscriber's channel.
subscribeEvents :: EventSink -> STM (TChan EdhValue, Maybe EdhValue)
subscribeEvents (EventSink !seqn !mrv !bcc !subc) = do
  subChan <- dupTChan bcc
  modifyTVar' subc $ \oldSubc ->
    let newSubc = oldSubc + 1
    in  if newSubc <= 0
         -- work with int64 overflow, wrap back to 1
          then 1
          else newSubc
  tryReadTChan subChan >>= \case
    Just ev -> return (subChan, Just ev)
    Nothing -> do
      sn <- readTVar seqn
      if sn == 0 -- no event ever posted yet
        then return (subChan, Nothing)
        else do
          lv <- readTVar mrv
          return (subChan, Just lv)

-- | Do event producing & consuming with an event sink
--
-- `consumerSetup` must trigger subsequent (though can be asynchronous as well as
-- synchronous) call(s) of `subscribeEvents`, or this will never progress.
--
-- `producerAction` won't be triggered until at least one new consumer subscribed
-- to the event sink.
setoffEvents :: EventSink -> IO () -> IO () -> IO ()
setoffEvents (EventSink _ _ _ !subc) !consumerSetup !producerAction = do
  subcBefore <- readTVarIO subc
  consumerSetup
  atomically $ do
    subcNow <- readTVar subc
    when (subcNow == subcBefore) retry
  producerAction

-- | Do event producing & consuming with an event sink
--
-- `consumerSetup` must trigger subsequent (though can be asynchronous as well as
-- synchronous) call(s) of `subscribeEvents`, or this will never progress.
--
-- `producerAction` won't be triggered until at least the specified `minConsumers`
-- new consumers subscribed to the event sink.
--
-- CAVEAT: the subscriber counter is currently implemented as a bounded int,
--         will suffer overflow problem if the event sink is reused and run some
--         time long enough.
setoffEvents' :: EventSink -> Int -> IO () -> IO () -> IO ()
setoffEvents' (EventSink _ _ _ !subc) !minConsumers !consumerSetup !producerAction
  = do
    when (minConsumers < 1)
      $ error
          "if no need to wait subscriber before producing events, you'd just go `publishEvent`"
    subcBefore <- readTVarIO subc
    consumerSetup
    atomically $ do
      subcNow <- readTVar subc
      when (subcNow < subcBefore)
        $ error "the rare thing happened, subscriber counter wrapped back"
      when (subcNow - subcBefore < minConsumers) retry
    producerAction

-- | publish (post) an event to a sink
publishEvent :: EventSink -> EdhValue -> STM ()
publishEvent (EventSink !seqn !mrv !chan _) val = do
  modifyTVar' seqn $ \oldSeq ->
    let newSeq = oldSeq + 1
    in  if newSeq <= 0
          -- work with int64 overflow, wrap back to 1
          then 1
          else newSeq
  writeTVar mrv val
  writeTChan chan val
