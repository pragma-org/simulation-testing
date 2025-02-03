module Moskstraumen.NodeId (module Moskstraumen.NodeId) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)

import Moskstraumen.Prelude

------------------------------------------------------------------------

newtype NodeId = NodeId Text
  deriving stock (Generic)
  deriving newtype (Eq, Ord, Show, IsString)
  deriving anyclass (FromJSON, ToJSON)

unNodeId :: NodeId -> Text
unNodeId (NodeId text) = text

makeNodeId :: Int -> NodeId
makeNodeId i = NodeId ("n" <> fromString (show i))
