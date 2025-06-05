module Moskstraumen.NodeId (module Moskstraumen.NodeId) where

import Data.Aeson (FromJSON, FromJSONKey, ToJSON, ToJSONKey)
import qualified Data.Text as Text

import Moskstraumen.Prelude

------------------------------------------------------------------------

-- start snippet NodeId
newtype NodeId = NodeId Text
  -- end snippet
  deriving stock (Generic)
  deriving newtype (Eq, Ord, Show, IsString, ToJSONKey, FromJSONKey)
  deriving anyclass (FromJSON, ToJSON)

unNodeId :: NodeId -> Text
unNodeId (NodeId text) = text

makeNodeId :: Int -> NodeId
makeNodeId i = NodeId ("n" <> fromString (show i))

isClientNodeId :: NodeId -> Bool
isClientNodeId (NodeId text) = "c" `Text.isPrefixOf` text
