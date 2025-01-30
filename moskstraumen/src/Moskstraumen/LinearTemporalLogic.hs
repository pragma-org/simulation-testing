module Moskstraumen.LinearTemporalLogic (module Moskstraumen.LinearTemporalLogic) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe
import Data.Time

import Moskstraumen.Message
import Moskstraumen.Prelude

------------------------------------------------------------------------

infixr 1 :==>
infixr 3 `And`
infix 4 :==
infix 4 :<=
infixl 6 :+
infixl 6 :-
infixl 9 :.

data Form a
  = TT
  | FF
  | Prop (a -> Bool)
  | Neg (Form a)
  | X (Form a)
  | U (Form a) (Form a)
  | Always (Form a)
  | Eventually (Form a)
  | Or (Form a) (Form a)
  | And (Form a) (Form a)
  | (:==>) (Form a) (Form a)
  | Term :<= Term
  | Term :== Term
  | FreezeQuantifier Var (Form a)

type Name = Text

data Term
  = Var Var
  | IntTerm Int
  | StringTerm Text
  | (:-) Term Term
  | (:+) Term Term
  | (:.) Term MessageField

type Var = Text

data MessageField = Kind | ArrivalTime | MsgId | InReplyTo

------------------------------------------------------------------------

-- [](request -> <>(response /\ request.id == response.id /\ response.time - request.time <= 100ms)
example :: Form Message
example =
  Always
    $ FreezeQuantifier "request"
    $ Prop (\msg -> msg.body.kind == "request")
    :==> Eventually
      ( FreezeQuantifier "response"
          $ Prop (\msg -> msg.body.kind == "response")
          `And` ( Var "response"
                    :. InReplyTo
                    :== Var "request"
                    :. MsgId
                )
          `And` ( ( Var "response"
                      :. ArrivalTime
                      :- Var "request"
                      :. ArrivalTime
                  )
                    :<= IntTerm 100
                )
      )

liveness :: Text -> Form Message
liveness req =
  Always
    $ FreezeQuantifier req
    $ Prop (\msg -> msg.body.kind == MessageKind req)
    :==> Eventually
      ( FreezeQuantifier
          resp
          ( Prop (\msg -> msg.body.kind == MessageKind resp)
              `And` Var resp
              :. InReplyTo
              :== Var req
              :. MsgId
          )
      )
  where
    resp = req <> "_ok"

------------------------------------------------------------------------

newtype Env a = Env
  { variables :: Map Var a
  }

emptyEnv :: Env a
emptyEnv = Env Map.empty

sat :: Form Message -> [Message] -> Env Message -> Bool
sat TT _w _env = True
sat FF _w _env = False
sat (Prop p) w _env = p (w !! 0)
sat (Neg p) w env = not (sat p w env)
sat (X p) w env = sat p (drop 1 w) env
sat (U p q) w env =
  case listToMaybe [i | i <- [0 .. length w - 1], sat q (drop i w) env] of
    Nothing -> False
    Just i -> and [sat p (drop k w) env | k <- [0 .. i - 1]]
sat (Always p) w env = and [sat p (drop i w) env | i <- [0 .. length w - 1]]
sat (Eventually p) w env = or [sat p (drop i w) env | i <- [0 .. length w - 1]]
sat (Or p q) w env = sat p w env || sat q w env
sat (And p q) w env = sat p w env && sat q w env
sat (p :==> q) w env = if sat p w env then sat q w env else True
sat (t1 :<= t2) _w env = eval t1 env <= eval t2 env
sat (t1 :== t2) _w env = eval t1 env == eval t2 env
sat (FreezeQuantifier x p) w env =
  sat p w env {variables = Map.insert x (w !! 0) env.variables}

eval :: Term -> Env Message -> LTLValue
eval (Var x) env = MessageValue (env.variables Map.! x)
eval (IntTerm i) _env = IntValue i
eval (StringTerm s) _env = StringValue s
eval (t1 :+ t2) env = case (eval t1 env, eval t2 env) of
  (IntValue i1, IntValue i2) -> IntValue (i1 + i2)
  _otherwise -> error "addition of non-integers"
eval (t1 :- t2) env = case (eval t1 env, eval t2 env) of
  (IntValue i1, IntValue i2) -> IntValue (i1 - i2)
  _otherwise -> error "subtraction of non-integers"
eval (t :. field) env = case eval t env of
  MessageValue msg -> case field of
    Kind -> KindValue msg.body.kind
    MsgId -> MaybeMessageIdValue msg.body.msgId
    InReplyTo -> MaybeMessageIdValue msg.body.inReplyTo
    ArrivalTime -> MaybeTimeValue msg.arrivalTime
  _otherwise -> error "field access on non-message"

data LTLValue
  = MessageValue Message
  | StringValue Text
  | IntValue Int
  | MaybeMessageIdValue (Maybe MessageId)
  | KindValue MessageKind
  | MaybeTimeValue (Maybe UTCTime)
  deriving (Eq, Ord, Show)

------------------------------------------------------------------------

{-
test :: Bool
test =
  and
    [ sat example [Message { kind = "request",  0 0, Message "response" 0 100] emptyEnv
    , not
        ( sat example [Message "request" 0 0, Message "response" 1 100] emptyEnv
        )
    , not
        ( sat example [Message "request" 0 0, Message "response" 0 101] emptyEnv
        )
    , sat example [Message "_equest" 0 0, Message "response" 0 100] emptyEnv
    , not
        ( sat example [Message "request" 0 0, Message "_esponse" 0 100] emptyEnv
        )
    , sat
        example
        [Message "foo" 0 0, Message "request" 0 0, Message "response" 0 100]
        emptyEnv
    ]

------------------------------------------------------------------------

generateMessages :: Int -> Int -> [Message]
generateMessages numberOfMessages duration = go [] 1 0
  where
    go acc n _time | n >= numberOfMessages + 1 = acc
    go acc n time
      | otherwise =
          go
            ( acc
                ++ [Message "request" n time, Message "response" n (time + duration)]
            )
            (n + 1)
            (time + duration)
 -}
