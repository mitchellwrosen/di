{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_HADDOCK not-home #-}

module Di.Core
 ( Di
 , new
 , log
 , log'
 , flush
 , flush'
 , throw
 , throw'
 , push
 , filter
 , onException
 , contralevel
 , contrapath
 , contramsg
 , Log(Log, log_time, log_level, log_path, log_message)
 ) where

import Control.Concurrent (forkFinally, myThreadId)
import Control.Concurrent.STM
  (STM, atomically, check, throwSTM,
   TQueue, writeTQueue, newTQueueIO, readTQueue, peekTQueue, isEmptyTQueue)
import qualified Control.Exception as Ex (BlockedIndefinitelyOnSTM)
import qualified Control.Exception.Safe as Ex
import Control.Monad (when, void)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Foldable (foldl')
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import qualified Data.Time.Clock.System as Time
import GHC.Conc (unsafeIOToSTM)
import Prelude hiding (log, filter)

--------------------------------------------------------------------------------

-- | @'Di' level path msg@ allows you to to log messages of type @msg@,
-- with a particular importance @level@, under a scope identified by @path@.
--
-- Each @msg@ gets logged together with its @level@, @path@ and the
-- UTC timestamp stating the instant when the logging request was made.
--
-- Even though logging is usually associated with rendering text, 'Di' makes no
-- assumption about the types of the @msg@ values being logged, nor the
-- @path@ values that convey their scope, nor the @level@ values that convey
-- their importance. Instead, it delays conversion from these precise types into
-- the ultimately desired raw representation (if any) as much as possible. This
-- makes it possible to log more precise information (for example, logging a
-- datatype of your own without having to convert it to text first), richer
-- scope paths (for example, the scope could be a 'Data.Map.Strict.Map' that
-- gets enriched with more information as we 'push' down the @path@), and
-- importance @level@s that are never too broad nor too narrow. This improves
-- type safety, as well as the composability of the @level@, @path@ and
-- @msg@ values. In particular, all of @level@, @path@ and @msg@ are
-- contravariant values, which in practice means including a precise 'Di' into a
-- more general 'Di' is always possible (see the 'contralevel', 'contrapath' and
-- 'contramsg' functions).
--
-- Undesired messages can be filtered by using 'filter'.
--
-- Contrary to other logging approaches based on monad transformers, a 'Di' is
-- a value that is expected to be passed around explicitly.
--
-- A 'Di' can be safely used concurrently, and messages are rendered in the
-- absolute order they were submitted for logging.
--
-- 'Di' is pronounced as \"dee" (not \"die" nor \"dye" nor \"day"). \"Di" is
-- the spanish word for an imperative form of the verb \"decir", which in
-- english means "to say", which clearly must have something to do with logging.
data Di level path msg = Di
  { di_filter :: !(level -> Seq path -> msg -> Bool)
    -- ^ Whether a particular combination of @level@, @path@s and @msg@ should
    -- be logged.
  , di_send :: !(Log level path msg -> STM ())
    -- ^ Send a 'Log' for processing.
  , di_flush :: !(STM ())
    -- ^ Block until all logs finish being processed.
  , di_logex :: Ex.SomeException -> Maybe (STM ())
    -- ^ If an exception deserves logging, then returns an 'STM' action
    -- that will perform the logging.
  }

--------------------------------------------------------------------------------

-- | Obtain a 'Di' that will use the given function to commit 'Log's to the
-- outside world.
--
-- Generally, you will want to call 'new' just once per application, right from
-- your @main@ function. That is:
--
-- @
-- main :: 'IO' ()
-- main = do
--    commit <- getSomeLogCommittingFunctionSomehow
--    'Di.new' commit $ \\di -> do
--        -- The rest of your program goes here.
--        -- You can start logging right away.
-- @
--
-- Using the obtained 'Di' concurrently is safe.
--
-- Note that by default, exceptions thrown using 'throw' won't be logged.
-- Please use 'onException' to change this behavior. Morevoer, the default
-- 'filter' on this 'Di' accepts all incoming logs.
new
  :: (MonadIO m, Ex.MonadMask m)
  => (Log level path msg -> IO ())
  -- ^ Function that commits 'Log's to the outside world.
  --
  -- For example, if you want to commit your 'Log's by displaying them
  -- in 'System.IO.stderr', then this is the function that should do the
  -- rendering and writing to 'System.IO.stderr'.
  --
  -- /Synchronous exceptions/ thrown by this function will be ignored.
  -- If you want to implement some retry or fallback mechanism, then
  -- you need to do it within this function. /Asynchronous exceptions/ not
  -- handled.
  --
  -- Notice that this function necessarily runs 'IO' and not @m@ because it will
  -- be performed in a different thread.
  -> (Di level path msg -> m a)
  -- ^ Within this scope, you can use the obtained 'Di' safely, even
  -- concurrently. As soon as @m a@ finishes, 'new' will block until
  -- all 'Log's have finished processing, before returning.
  --
  -- /WARNING:/ Even while @'new' commit 'pure' :: m ('Di' level path msg)@
  -- type-checks, and you can use it to work with the 'Di' outside the
  -- intended scope, you will have to remember to call 'flush' yourself
  -- before exiting your application. Otherwise, some log messages may
  -- be left unprocessed. If possible, use the 'Di' within this function
  -- and don't let it escape this scope.
  -> m a -- ^
new commit act = do
    tqLogs :: TQueue (Log level path msg) <- liftIO newTQueueIO
    -- Start worker thread. The worker thread can only ever fail with an
    -- asynchronous exception (see `worker`). If that happens, then re-throw it
    -- to this thread.
    void $ liftIO $ do
       me <- myThreadId
       forkFinally (worker tqLogs)
                   (either (Ex.throwTo me) pure)
    let di = Di { di_filter = \_ _ _ -> True
                , di_send = writeTQueue tqLogs
                , di_logex = \_ -> Just (pure ())
                , di_flush = check =<< isEmptyTQueue tqLogs }
    -- By flushing before returning we ensure all messages are logged. This
    -- is the main reason why 'new' limits the 'Di' scope as it does.
    Ex.finally (act di) (flush di)
  where
    -- worker :: TQueue (Log level path msg) -> IO ()
    worker tqLogs = do
      -- We use 'peekTQueue' in order to get the 'Log' from the queue in order
      -- to process it, and we remove it from the queue after processing
      -- (successfully or not). By doing this, we can get 'di_flush' to work by
      -- simply checking whether `tqLogs` is empty. This works because 'worker'
      -- is the only reader of `tqLogs`, so we can be sure nobody else will read
      -- the queue.
      Ex.try (atomically (peekTQueue tqLogs)) >>= \case
         Right log_ -> do
            -- Notice that we mute synchronous exceptions because 'commit'
            -- already should include a fallback printing mechanism, and if that
            -- fallback fails there's not much else we could do. So we just mute
            -- synchronous exceptions and move on to the next iteration.
            Ex.catch (Ex.finally (commit log_)
                                 (atomically (readTQueue tqLogs)))
                     (\(_ :: Ex.SomeException) -> pure ())
            worker tqLogs
         Left (se :: Ex.SomeException) -> case Ex.fromException se of
            -- Nobody is writing to `tqLogs` anymore, we can just stop.
            Just (_ :: Ex.BlockedIndefinitelyOnSTM) -> pure ()
            -- Some unexpected sync exception. We don't care. Continue.
            Nothing -> worker tqLogs

-- | Log a message @msg@ with a particular importance @level@.
--
-- This function is like 'log', but it doesn't require a 'MonadIO'
-- constraint. Instead, it asks for a /natural transformation/ that will be
-- used in order to run 'STM' actions in @m@.
--
-- First, this allows you to log from any 'Monad' that wraps 'IO' without
-- necessarily having a 'MonadIO' instance. For example:
--
-- @
-- newtype Foo = Foo ('IO' a)
--   deriving ('Functor', 'Applicative', 'Monad')
--
-- 'log'' (Foo . 'atomically')
--      :: 'Di' level path msg -> level -> msg -> Foo ()
-- @
--
-- Second, this 'log'' function allows @m@ to be 'STM' itself:
--
-- @
-- 'log'' 'id'
--      :: 'Di' level path msg -> level -> msg -> 'STM' ()
-- @
--
-- The semantics of logging from within 'STM' are those of any other 'STM'
-- transaction: That is, a log message is commited only once to the outside
-- world if and when the 'STM' transaction succeeds. That is, the following
-- example will only ever commit the log containing @ly@ and @my@, and not
-- the one containing @lx@ and @mx@.
--
-- @
-- 'atomically'
--    ('log'' 'id' di lx mx >> 'Control.Concurrent.STM.retry') \<|>
--    ('log'' 'id' di ly my)
-- @
--
-- Furthermore, much like we were able to log from a @Foo@ that wrapped 'IO'
-- in the previous example, we are also able to log from any monad wrapping
-- 'STM':
--
-- @
-- newtype Bar = Bar ('STM' a)
--   deriving ('Functor', 'Applicative', 'Monad')
--
-- 'log'' Bar
--      :: 'Di' level path msg -> level -> msg -> Bar ()
-- @
--
-- This function returns immediately after queing the message for
-- asynchronously committing the message in a different thread. If you want
-- to explicitly wait for the message to be committed, then call 'flush'
-- afterwards.
--
-- Log messages are rendered in FIFO order, and their timestamp records the time
-- when this 'log'' function was called, rather than the time when the log
-- message is committed in the future.
--
-- /Note regarding exceptions:/ Any exception thrown by the given
-- natural transformation will be thrown here. /Synchronous/ exceptions that
-- happen due to failures in the actual committing of the log message are
-- handled by attempting to log the message to 'IO.stderr' as a fallback if
-- possible. /Asynchronous/ exceptions happening as part of the committing
-- process will be thrown in a different thread, and are not not explicitly
-- handled. /Pure/ exceptions originating from the 'filter' function will be
-- thrown here. In practical terms, this means that unless you know what you
-- are doing, you should just call 'log'' without worrying about it ever
-- throwing exceptions.
log'
  :: Monad m
  => (forall x. STM x -> m x)
  -- ^ Natural transformation from 'STM' to @m@.
  --
  -- Note that it is not necessary for this /natural transofmation/ to be a
  -- /monad morphism/ as well. That is, using 'atomically' here is acceptable.
  -> Di level path msg  -- ^ Where to log to.
  -> level              -- ^ Log importance level.
  -> msg                -- ^ Log message.
  -> m ()
log' nat di l = \m ->
   -- 'mempty' gets prepended to the current path, which is already hardcoded
   -- inside 'di_filter' and 'di_send'.
   when (di_filter di l mempty m) $ do
      -- Note: We call 'nat' twice because we don't want the call to
      -- 'getSystemTimeSTM' to be affected by 'di_send' retries, if possible.
      -- We accomplish this whenever 'nat' wraps 'atomically' somehow.
      ts <- nat getSystemTimeSTM
      nat (di_send di (Log ts l mempty m))
{-# INLINABLE log' #-}

-- | Log a message @msg@ with a particular importance @level@.
--
-- Notice that function requires a 'MonadIO' constraint. If you want to log
-- from other monads that don't satisfy this constraint but are somehow able
-- to perform or build 'STM' actions, then use 'log'' instead.
--
-- This function returns immediately after queing the message for
-- asynchronously committing the message in a different thread. If you want
-- to explicitly wait for the message to be committed, then call 'flush'
-- afterwards.
--
-- Log messages are rendered in FIFO order, and their timestamp records the time
-- when this 'log'' function was called (rather than the time when the log
-- message is committed in the future).
--
-- /Note regarding exceptions:/ Synchronous/ exceptions that happen due to
-- failures in the actual committing of the log message are handled by
-- attempting to log the message to 'IO.stderr' as a fallback if
-- possible. /Asynchronous/ exceptions happening as part of the committing
-- process will be thrown in a different thread, and are not not explicitly
-- handled. /Pure/ exceptions originating from the 'filter' function will be
-- thrown here. In practical terms, this means that unless you know what you
-- are doing, you should just call 'log'' without worrying about it ever
-- throwing exceptions.
log
  :: MonadIO m
  => Di level path msg  -- ^ Where to log to.
  -> level              -- ^ Log importance level.
  -> msg                -- ^ Log message.
  -> m ()
log di l = log' (liftIO . atomically) di l
{-# INLINE log #-}

-- | Block until all messages being logged have finished processing.
--
-- If the 'MonadIO' constraint can't be satisfied, then use 'flush'' instead.
--
-- Manually calling 'flush' is not usually necessary because 'new' does it
-- already, if at some point you want to ensure that all messages logged
-- until then have properly commited, then 'flush' will block until that
-- happens.
--
-- Additionally, if 'Di' has left the scope intended by 'new' (which is
-- acceptable), you will be responsible for calling 'flush' yourself.
flush :: MonadIO m => Di level path msg -> m ()
flush = \di -> flush' (liftIO . atomically) di
{-# INLINE flush #-}

-- | This is like 'flush', but it doesn't require a 'MonadIO' constraint.
--
-- More generally, 'flush'' is to 'flush' as 'log'' is to 'log'. So, refer
-- to 'log'' for more documentation on how to use this 'flush''.
flush'
  :: (forall x. STM x -> m x)
  -- ^ Natural transformation from 'STM' to @m@.
  --
  -- Note that it is not necessary for this /natural transofmation/ to be a
  -- /monad morphism/ as well. That is, using 'atomically' here is acceptable.
  -> Di level path msg
  -> m ()
flush' nat di = nat (di_flush di)
{-# INLINE flush' #-}

-- | This is like 'throw', but it doesn't require a 'MonadIO' constraint.
throw'
  :: (Monad m, Ex.Exception e)
  => (forall x. STM x -> m x)
  -- ^ Natural transformation from 'STM' to @m@.
  --
  -- Note that it is not necessary for this /natural transofmation/ to be a
  -- /monad morphism/ as well. That is, using 'atomically' here is acceptable.
  --
  -- WARNING: Note that while this function can be 'id', calling 'throw'' from
  -- 'STM' *will not log* the exception, just throw it. This might change in the
  -- future if we figure out how to make it work safely.
  -> Di level path msg
  -> e  -- ^ 'Ex.Exception'.
  -> m a
throw' nat di = \e -> do
  -- If logging throws an exception, then it will be propagated instead of `e`.
  nat (sequence_ (di_logex di (Ex.toException e)))
  -- By throwing from inside 'STM' we avoid potentially entering into an
  -- infinite loop in case the implementation of 'Ex.throwM' would take us back
  -- to 'throw''. Also, notice that we need to call `nat` again here, otherwise
  -- if we were to run `throwSTM` in the same transaction as `di_logex`, the
  -- transaction would be aborted and never be sent.
  nat (throwSTM e)
{-# INLINABLE throw' #-}

-- | Throw an 'Ex.Exception', but not without logging it first according to the
-- rendering rules established by 'onException', and further restricted by the
-- filtering rules established by 'filter'.
--
-- If the exception is not logged, then this function behaves as 'Ex.throwM'.
--
-- @
-- 'throw' ('onException' ('const' 'False') di)  ==  'Ex.throwM'
-- @
throw
  :: (MonadIO m, Ex.MonadMask m, Ex.Exception e)
  => Di level path msg
  -> e  -- ^ 'Ex.Exception'.
  -> m a
throw di = throw' (liftIO . atomically) di
{-# INLINABLE throw #-}

-- | Modifies a 'Di' so that exceptions thrown with 'throw' could be logged as a
-- @msg@ with a particular @level@ if both the passed in function returns
-- 'Just', and 'filter' so allows it afterwards.
--
-- If the given function returns 'Nothing', then no logging is performed.
--
-- The returned @'Seq' path@ will extend the 'path' /at the throw site/ before
-- sending the log. The leftmost @path@ is closest to the root.
--
-- Composition:
--
-- @
-- 'onException' f . 'onException' g   ==   'onException' (g e *> f e)
-- @
--
-- Notice that the @level@, @path@s and @msg@ resulting from @g@ are discarded,
-- yet its policy regarding whether to log or not is preserved in the same way
-- as 'filter'. That is, 'onException' can't accept an exception already
-- rejected by a previous use of 'onException', but it can reject a previously
-- accepted one.
onException
  :: (Ex.SomeException -> Maybe (level, Seq path, msg))
  -> Di level path msg
  -> Di level path msg  -- ^
onException f = \di0 -> di0
  { di_logex = \se -> do
      _ <- di_logex di0 se
      (l, ps, m) <- f se
      let di1 = foldl' (flip push) di0 ps
      Just (log' id di1 l m)
  }

-- | Returns a new 'Di' on which only messages with @level@, @path@s and
-- @msg@ satisfying the given predicate—in addition to any previous
-- 'filter's—are ever logged.
--
-- Identity:
--
-- @
-- 'filter' (\\_ _ _ -> 'True')  ==  'id'
-- @
--
-- Composition:
--
-- @
-- 'filter' (\\l ps m -> f l ps m '&&' g l ps m)  ==  'filter' f . 'filter' g
-- @
--
-- Notice how 'filter' can't accept a message already rejected by a previous use
-- of 'filter', yet it can reject a previously accepted one.
--
-- Commutativity:
--
-- @
-- 'filter' f . 'filter' g  ==  'filter' g . 'filter' f
-- @
filter
  :: (level -> Seq path -> msg -> Bool)
  -- ^ Whether a particular log entry with the given @level@, @path@s and
  -- @msg@ should be logged.
  --
  -- The given @path@s indicate where the 'log' call was made from, with an
  -- empty 'Seq' representing 'log' calls made at the current depth level
  -- (see 'push'). The leftmost @path@ in the 'Seq' is the most immediate
  -- child, while the rightmost is the most distand child (i.e., the @path@
  -- closest to the place where 'log' call actually took place).
  -> Di level path msg
  -> Di level path msg
filter f = \di ->
  di { di_filter = \l ps m -> f l ps m && di_filter di l ps m }
{-# INLINABLE filter #-}

-- | Push a new @path@ to the 'Di'.
push :: path -> Di level path msg -> Di level path msg
push p = \di -> di
  { di_send = \x -> di_send di (x { log_path = p Seq.<| log_path x })
  , di_filter = \l ps m -> di_filter di l (p Seq.<| ps) m }
{-# INLINABLE push #-}

-- | A 'Di' is contravariant in its @level@ argument.
--
-- This function is used to go from a /more general/ to a /more specific/ type
-- of @level@. For example, @data Level = Info | Error@ is a more specific type
-- than @data Level' = Info' | Warning' | Error'@, since the former can only
-- convey two logging levels, whereas the latter can convey three. We can
-- convert from the more general to the more specific @level@ type using this
-- 'contralevel' function:
--
-- @
-- 'contralevel' (\\case { Info -> Info'; Error -> Error' })
--             (di :: 'Di' Level' 'String' msg)
--     :: 'Di' Level 'String' msg
-- @
--
-- Identity:
--
-- @
-- 'contralevel' 'id'   ==   'id'
-- @
--
-- Composition:
--
-- @
-- 'contralevel' (f . g)   ==   'contralevel' g . 'contralevel' f
-- @
contralevel
  :: (level -> level') -> Di level' path msg -> Di level path msg
contralevel f = \di -> di
  { di_send = \x -> di_send di (x { log_level = f (log_level x) })
  , di_filter = \l ps m -> di_filter di (f l) ps m }
{-# INLINABLE contralevel #-}

-- | A 'Di' is contravariant in its @path@ argument.
--
-- This function is used to go from a /more general/ to a /more specific/ type
-- of @path@. For example, 'Int' is a more specific type than 'String',
-- since the former clearly conveys the idea of a number, whereas the
-- latter could be anything that is representable as 'String', such as
-- names of fruits and poems. We can convert from the more general to the
-- more specific @path@ type using this 'contrapath' function:
--
-- @
-- 'contrapath' 'show' (di :: 'Di' level 'String' msg)
--     :: 'Di' 'Int' msg
-- @
--
-- Identity:
--
-- @
-- 'contrapath' 'id'   ==   'id'
-- @
--
-- Composition:
--
-- @
-- 'contrapath' (f . g)   ==   'contrapath' g . 'contrapath' f
-- @
contrapath :: (path -> path') -> Di level path' msg -> Di level path msg
contrapath f = \di -> di
  { di_send = \x -> di_send di (x { log_path = fmap f (log_path x) })
  , di_filter = \l ps m -> di_filter di l (fmap f ps) m
  }
{-# INLINABLE contrapath #-}

-- | A 'Di' is contravariant in its @msg@ argument.
--
-- This function is used to go from a /more general/ to a /more specific/ type
-- of @msg@. For example, 'Int' is a more specific type than @'String'@, since
-- the former clearly conveys the idea of a numbers, whereas the latter could be
-- a anything that is representable as 'String', such as names of painters and
-- colors. We can convert from the more general to the more specific @msg@ type
-- using this 'contramsg' function:
--
-- @
-- 'contramsg' 'show' (di :: 'Di' level path 'String')
--     :: 'Di' level path 'Int'
-- @
--
-- Identity:
--
-- @
-- 'contramsg' 'id'   ==   'id'
-- @
--
-- Composition:
--
-- @
-- 'contramsg' (f . g)   ==   'contramsg' g . 'contramsg' f
-- @
contramsg
  :: (msg -> msg') -> Di level path msg' -> Di level path msg
contramsg f = \di -> di
  { di_send = \x -> di_send di (x { log_message = f (log_message x) })
  , di_filter = \l ps m -> di_filter di l ps (f m) }
{-# INLINABLE contramsg #-}

--------------------------------------------------------------------------------

data Log level path msg = Log
  { log_time :: !Time.SystemTime
    -- ^ First known timestamp when the log was generated.
    --
    -- We use 'Time.SystemTime' rather than 'Time.UTCTime' because it is
    -- cheaper to obtain and to render. You can use
    -- 'Data.Time.Clock.System.systemToUTCTime' to convert it if necessary.
  , log_level :: !level
    -- ^ Importance level of the logged message (e.g., “info”, “warning”,
    -- “error”, etc.).
  , log_path :: !(Seq path)
    -- ^ Path where the logged message was created from.
    --
    -- The leftmost @path@ is the root @path@. The rightmost @path@ is the
    -- @path@ closest to where the log was generated.
  , log_message :: !msg
    -- ^ Human-readable message itself.
  } deriving (Eq, Show)

--------------------------------------------------------------------------------

getSystemTimeSTM :: STM Time.SystemTime
{-# INLINE getSystemTimeSTM #-}
getSystemTimeSTM = unsafeIOToSTM Time.getSystemTime

