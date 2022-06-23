{-# Language KindSignatures, DataKinds #-}
module RTS.ParserVM where

import Data.Text(Text)
import Data.IntSet(IntSet)
import qualified Data.IntSet as Set

import qualified RTS.Input as RTS
import qualified RTS.Vector as RTS
import qualified RTS.Numeric as RTS
import qualified RTS.ParserAPI as PAPI

-- | A direct parser.  Used for parsers that do not use unbiased chocie.
type DParser m a = ParserErrorState -> m (Maybe (a,RTS.Input), ParserErrorState)

-- | A continuation parser.  Used for parsers that use unbiased choice.
type CParser r m a  = NoCont r m -> YesCont r m a -> Code r m

type Thread r m     = Bool -> Code r m

type Code r m       = ThreadState r m -> m (ThreadState r m)
type YesCont r m a  = a -> RTS.Input -> Code r m
type NoCont r m     = Code r m

data ThreadState r m = ThreadState
  { thrNotified      :: !IntSet
  , thrStack         :: [Thread r m]
  , thrThreadNum     :: !Int    -- ^ Number of live threads, used to assign ids.
  , thrResults       :: [r]
  , thrErrors        :: ParserErrorState
  }

data ParserErrorState = ParserErrorState -- XXX

thrUpdateErrors ::
  (ParserErrorState -> ParserErrorState) -> ThreadState r m -> ThreadState r m
thrUpdateErrors f s = s { thrErrors = f (thrErrors s) }


vmNoteFail ::
  PAPI.ParseErrorSource ->
  Text ->
  RTS.Input ->
  RTS.Vector (RTS.UInt 8) ->
  ParserErrorState ->
  ParserErrorState
vmNoteFail = undefined

vmPushDebugTail :: Text -> ParserErrorState -> ParserErrorState
vmPushDebugTail = undefined

vmPushDebugCall :: Text -> ParserErrorState -> ParserErrorState
vmPushDebugCall = undefined

vmPopDebug :: ParserErrorState -> ParserErrorState
vmPopDebug = undefined

vmOutput :: r -> ThreadState r m -> ThreadState r m
vmOutput r s = s { thrResults = r : thrResults s }

vmNotify :: Int -> ThreadState r m -> ThreadState r m
vmNotify tid s = s { thrNotified = Set.insert tid (thrNotified s) }

vmSpawn :: (Bool -> Code r m) -> ThreadState r m -> (Int,ThreadState r m)
vmSpawn code s = (tid, newS)
  where
  tid  = thrThreadNum s
  newS = s { thrThreadNum = tid + 1
           , thrStack = code : thrStack s
           }

vmIsNotified :: Int -> ThreadState r m -> Bool
vmIsNotified tid s = tid `Set.member` thrNotified s

vmYield :: Applicative m => Code r m
vmYield s =
  case thrStack s of
    [] -> pure s
    code : more ->
      let tid  = thrThreadNum s - 1
          note = thrNotified s
          n    = tid `Set.member` thrNotified s
          s1   = s { thrThreadNum = tid
                   , thrStack     = more
                   , thrNotified  = if n then Set.delete tid note else note
                   }
      in code n s1


