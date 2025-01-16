{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeOperators #-}

module Moskstraumen.Marshal (module Moskstraumen.Marshal) where

import GHC.Generics

import Moskstraumen.Message
import Moskstraumen.Prelude

------------------------------------------------------------------------

class GMarshal f where
  gmarshal :: f a -> [(MessageKind, [(Field, Value)])]

instance GMarshal U1 where
  gmarshal U1 = []

instance (GMarshal a, GMarshal b) => GMarshal (a :*: b) where
  gmarshal (x :*: y) = gmarshal x ++ gmarshal y

instance (GMarshal a, GMarshal b) => GMarshal (a :+: b) where
  gmarshal (L1 x) = undefined
  gmarshal (R1 x) = undefined

instance (Selector s) => GMarshal (M1 S s f) where
  gmarshal (M1 x) = undefined -- gmarshal x

instance GMarshal (K1 i a) where
  gmarshal (K1 x) = undefined

------------------------------------------------------------------------

class Marshal a where
  marshal :: a -> [(MessageKind, [(Field, Value)])]
  default marshal ::
    (Generic a, GMarshal (Rep a)) => a -> [(MessageKind, [(Field, Value)])]
  marshal = gmarshal . from
