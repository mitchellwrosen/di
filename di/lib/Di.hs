{-# LANGUAGE OverloadedStrings #-}
-- | This module is a highly opinionated, basic, and yet sufficient
-- choice of a concrete stack of logging solutions belonging to the [di
-- logging ecosystem](https://github.com/k0001/di)—an otherwise rather
-- general ecosystem, flexible and full of choices.
--
-- For most logging scenarios out there, the choices made here should suffice,
-- but if you find these are not sufficient for your particular use case, please
-- refer to other libraries of the /di logging ecosystem/ such as
-- [di-core](https://hackage.haskell.org/package/di-core),
-- [di-monad](https://hackage.haskell.org/package/di-monad),
-- [di-handle](https://hackage.haskell.org/package/di-handle), or
-- [di-df1](https://hackage.haskell.org/package/di-df1), and you are likely
-- to find a compatible and composable solution there. For this reason, staring
-- with this package rather than one of the those other lower-level packages is
-- always recommended.
--
-- The choices made here are:
--
-- * We encourage a [mtl](https://hackage.haskell.org/package/mtl) approach
--   through a typeclass called 'Di.Monad.MonadDi', for which all of the
--   monad transformers in
--   [transformers](https://hackage.haskell.org/package/transformers) and
--   [pipes](https://hackage.haskell.org/package/pipes) have instances.
--
-- * We provide our own 'Di.Monad.DiT' monad transformer which
--   has a 'MonadDi' instance, as well as instances for all the relevant
--   typeclasses in the
--   [base](https://hackage.haskell.org/package/base),
--   [mtl](https://hackage.haskell.org/package/mtl), and
--   [exceptions](https://hackage.haskell.org/package/exceptions) libraries.
--   All of the 'MonadDi' instances exported by this package expect a
--   'DiT' transformer in the stack somewhere, and defer all work to it.
--
-- * We embrace the [df1](https://hackage.haskell.org/package/df1) hierarchical
--   structured logging format, both at the type-level and when rendering the
--   log lines as text. Most notably, this means that we embrace the /df1/
--   importance 'Df1.Level's.
--
-- * We commit logs to the outside world by printing them to 'System.IO.stderr'.
--
-- * Exceptions are logged at their throw site (see 'Di.Core.onException').
--
-- You will notice that some of the functions in this module mention the types
-- 'Df1.Level', 'Df1.Path' and 'Df1.Message', and some other functions
-- talk about @level@, @path@ and @msg@ type variables. This is
-- because even while our particular set of choices require some monomorphic
-- types, as demonstrated by the 'Di.Df1.Df1' and 'Di.Df1.Monad.MonadDf1'
-- type-synonyms, the larger /di logging ecosystem/ treats these values
-- polymorphically, so they will show up in the types in one way or another,
-- either in concrete or polymorphic form. This can seem a bit noisy, but the
-- good news is that if, for example, want to call a third party library that
-- uses other types for conveying the idea of a “log importance level” or a “log
-- message”, then you can do so if you can convert between these different
-- types. You are of course encouraged to use the 'Di.Df1.Df1' and
-- 'Di.Df1.Monad.MonadDf1' type-synonyms yourself.  For more information about
-- this, see "Di.Monad" and "Di.Core", but not today.
--
-- The intended usage of this module is:
--
-- @
-- import qualified "Di"
-- @
module Di
 ( new
 , Di.Df1.Df1

   -- * Monadic API
 , Di.Df1.Monad.MonadDf1

   -- ** Hierarchy
 , Di.Df1.Monad.push
 , Df1.Path
 , Df1.Segment
 , Df1.ToSegment(segment)

   -- ** Metadata
 , Di.Df1.Monad.attr
 , Df1.Key
 , Df1.ToKey(key)
 , Df1.Value
 , Df1.ToValue(value)

   -- ** Messages
 , Df1.Level
 , Df1.Message
 , Df1.ToMessage(message)
 , Di.Df1.Monad.debug
 , Di.Df1.Monad.info
 , Di.Df1.Monad.notice
 , Di.Df1.Monad.warning
 , Di.Df1.Monad.error
 , Di.Df1.Monad.alert
 , Di.Df1.Monad.critical
 , Di.Df1.Monad.emergency

   -- ** Exceptions
 , Di.Monad.throw

   -- * Basic DiT support
 , Di.Df1.Monad.Df1T
 , Di.Monad.runDiT
 , Di.Monad.hoistDiT
 ) where

import Control.Monad.Catch as Ex
import Control.Monad.IO.Class (MonadIO)
import Data.Sequence (Seq)
import Data.String (fromString)

import qualified Df1
import qualified Di.Core
import qualified Di.Df1
import qualified Di.Df1.Monad
import qualified Di.Handle
import qualified Di.Monad

--------------------------------------------------------------------------------

-- | Obtain a 'Di.Core.Di' that will write logs in the /df1/ format to
-- 'System.IO.stderr'.
--
-- Generally, you will want to call 'new' just once per application, right from
-- your @main@ function. For example:
--
-- @
-- main :: 'IO' ()
-- main = do
--    'new' $ \\di -> do
--       -- /The rest of your program goes here./
--       -- /You can start logging right away./
--       'Di.Monad.runDiT' di $ do
--           'Di.Df1.Monad.notice' "Welcome to my program!"
--           -- /You can use 'Di.Df1.Monad.push' to separate different/
--           -- /logging scopes of your program:/
--           'Di.Df1.Monad.push' "initialization" $ do
--               -- /something something do initialization/
--               'Di.Df1.Monad.notice' "Starting web server"
--           'Di.Df1.Monad.push' "server" $ do
--               -- /And you can use 'Di.Df1.Monad.attr' to add metadata to/
--               -- /messages logged within a particular scope./
--               'Di.Df1.Monad.attr' "port" "80" $ do
--                    'Di.Df1.Monad.info' "Listening for new clients"
--                    clientAddress <- /somehow get a client connection/
--                    'Di.Df1.Monad.push' "handler" $ do
--                       'Di.Df1.Monad.attr' "client-address" clientAddress $ do
--                          'Di.Df1.Monad.info' "Connection established"
--                          -- /If you throw an exception with 'Di.Monad.throw',/
--                          -- /it will be logged automatically./
--                          'Di.throw' ('userError' "Oops!")
-- @
--
-- That program will render something like this to 'System.IO.stderr' (in colors!):
--
-- @
-- 2018-05-06T19:48:06.194579393Z NOTICE Welcome to my program!
-- 2018-05-06T19:48:06.195041422Z \/initialization NOTICE Starting web server
-- 2018-05-06T19:48:06.195052862Z \/server port=80 INFO Listening for new clients
-- 2018-05-06T19:48:06.195059084Z \/server port=80 \/handler client%2daddress=192%2e168%2e0%2e25%3a32528 INFO Connection established
-- 2018-05-06T19:48:06.195059102Z \/server port=80 \/handler client%2daddress=192%2e168%2e0%2e25%3a32528 exception=user%20error%20(Oops!) WARNING Exception thrown
-- @
--
-- Notice that by default, /all/ exceptions thrown using 'Di.Monad.throw'
-- are logged /at their throw site/ with 'Df1.Warning' level.
--
-- (Unrelated: Notice how /df1/ escapes pretty much all punctuation characters.
-- This is temporal until the /df1/ format is formalized and a more limited set
-- of punctuation characters is reserved.)
new
  :: (MonadIO m, Ex.MonadMask m)
  => (Di.Core.Di Df1.Level Df1.Path Df1.Message -> m a)
  -- ^ /This type is the same as @'Di.Df1.Df1' -> m a@./
  --
  -- ^ Within this scope, you can use the obtained 'Di.Core.Di' safely, even
  -- concurrently. As soon as @m a@ finishes, 'new' will block until
  -- all logs have finished processing, before returning.
  --
  -- /WARNING:/ Even while @'new' commit 'pure' :: m ('Di.Core.Di' 'Df1.Level'
  -- 'Df1.Path' 'Df1.Message')@ type-checks, attempting to use the obtained 'Di'
  -- outside its intended scope will fail.
  -> m a -- ^
new act = do
  commit <- Di.Handle.stderr Di.Df1.df1
  Di.Core.new commit $ \di -> do
     act (Di.Core.onException exceptionHandler di)

exceptionHandler
  :: Ex.SomeException
  -> Maybe (Df1.Level, Seq Df1.Path, Df1.Message)
{-# INLINE exceptionHandler #-}
exceptionHandler = \se -> Just
  ( Df1.Warning
  , pure (Df1.Attr "exception" (fromString (show se)))
  , "Exception thrown"
  )

