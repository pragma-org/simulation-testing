{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Moskstraumen.Marshal (module Moskstraumen.Marshal) where

-- https://www.stephendiehl.com/posts/generics/
-- https://stackoverflow.com/questions/42583838/generically-build-parsers-from-custom-data-types

import Data.ByteString (ByteString)
import qualified Data.Text as Text
import GHC.Generics

import Moskstraumen.Message
import Moskstraumen.Prelude

------------------------------------------------------------------------

data Item
  = MessageKindItem MessageKind [Item]
  | FieldItem Field [Item]
  | ValueItem Value
  deriving (Show)

class GMarshal f where
  gmarshal :: f a -> [Item] -- (MessageKind, [(Field, Value)])]

instance GMarshal U1 where
  gmarshal U1 = []

instance (GMarshal a, GMarshal b) => GMarshal (a :*: b) where
  gmarshal (x :*: y) = gmarshal x ++ gmarshal y

instance (GMarshal a, GMarshal b) => GMarshal (a :+: b) where
  gmarshal (L1 x) = gmarshal x
  gmarshal (R1 x) = gmarshal x

-- Selector Metadata
instance (GMarshal f, Selector c) => GMarshal (M1 S c f) where
  gmarshal (M1 x) = [FieldItem (Field (Text.pack (selName m))) (gmarshal x)]
    where
      m = undefined :: t c f a

-- Constructor Metadata
instance (GMarshal f, Constructor c) => GMarshal (M1 C c f) where
  gmarshal (M1 x) =
    [ MessageKindItem
        (MessageKind (Text.pack (conName m)))
        (gmarshal x)
    ]
    where
      m = undefined :: t c f a

-- Datatype
instance (GMarshal f) => GMarshal (M1 D x f) where
  gmarshal (M1 x) = gmarshal x

-- Constructor Paramater
instance (IsValue f) => GMarshal (K1 R f) where
  gmarshal (K1 x) = [ValueItem (isValue x)]

class IsValue a where
  isValue :: a -> Value

instance IsValue Text where
  isValue = String

instance IsValue [Text] where
  isValue = List . map String

------------------------------------------------------------------------

class Marshal a where
  marshal :: a -> [Item] -- (MessageKind, [(Field, Value)])]
  default marshal ::
    (Generic a, GMarshal (Rep a)) => a -> [Item] -- (MessageKind, [(Field, Value)])]
  marshal = gmarshal . from

------------------------------------------------------------------------

data EchoInput =
  -- = Init {node_id :: Text, node_ids :: [Text]}
  Echo {echo :: Text}
  deriving stock (Generic, Show)
  deriving anyclass (Marshal, Unmarshal)

-- test :: Bool
test =
  -- marshal (Init "a" ["b"])
  marshal (Echo "a")

-- == [("Init", [("node_id", String "a"), ("node_ids", List [String "b"])])]

------------------------------------------------------------------------

class Unmarshal a where
  unmarshal :: (MessageKind, [(Field, Value)]) -> Either String a
  default unmarshal ::
    (Generic a, GUnmarshal (Rep a)) =>
    (MessageKind, [(Field, Value)])
    -> Either String a
  unmarshal = fmap to . gunmarshal

class GUnmarshal f where
  gunmarshal :: (MessageKind, [(Field, Value)]) -> Either String (f a)

instance GUnmarshal U1 where
  gunmarshal _ = Right U1

instance (GUnmarshal a, GUnmarshal b) => GUnmarshal (a :*: b) where
  gunmarshal = undefined

instance (GUnmarshal a, GUnmarshal b) => GUnmarshal (a :+: b) where
  gunmarshal = undefined

-- Selector Metadata
instance (GUnmarshal f, Selector c) => GUnmarshal (M1 S c f) where
  gunmarshal x@(kind, fieldValues) = case lookup field fieldValues of
    Nothing -> undefined
    Just _value -> M1 <$> gunmarshal x
    where
      field = Field (Text.pack (selName m))
      m = undefined :: t c f a

-- Constructor Metadata
instance (GUnmarshal f, Constructor c) => GUnmarshal (M1 C c f) where
  gunmarshal x@(MessageKind kind, fieldValues) =
    if kind == Text.pack (conName m)
      then M1 <$> gunmarshal x
      else undefined
    where
      m = undefined :: t c f a

-- Datatype
instance (GUnmarshal f) => GUnmarshal (M1 D x f) where
  gunmarshal = fmap M1 . gunmarshal

-- Constructor Paramater
instance (UnmarshalValue f) => GUnmarshal (K1 R f) where
  gunmarshal = undefined

class UnmarshalValue a where
  unmarshalValue :: Value -> Either String a

instance UnmarshalValue Text where
  unmarshalValue (String text) = Right text

t = unmarshal ("Echo", [("echo", "a")]) :: Either String EchoInput
