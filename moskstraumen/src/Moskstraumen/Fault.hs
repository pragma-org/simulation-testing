module Moskstraumen.Fault (module Moskstraumen.Fault) where

import Moskstraumen.Generate
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Time

------------------------------------------------------------------------

data Fault = PartitionFault Partition
  deriving (Eq, Show)

data Partition
  = None
  | -- | Isolate a single node.
    One NodeId
  | -- | A majority and minority split.
    Majority [NodeId]
  deriving (Eq, Show)

affected :: NodeId -> NodeId -> Partition -> Bool
affected src dest (One isolated) = src == isolated || dest == isolated
affected src dest (Majority majority) =
  src
    `elem` majority
    && dest
    `notElem` majority
    || src
    `notElem` majority
    && dest
    `elem` majority
affected _src _dest None = False

generatePartitions ::
  [NodeId] -> (Time, Time) -> Int -> Gen [(Time, Partition)]
generatePartitions nodes (start, end) durationMicros = go start []
  where
    go time acc
      | time' >= end = return (reverse acc)
      | otherwise = do
          partition <- generatePartition nodes
          go time' ((time', None) : (time, partition) : acc)
      where
        time' = addTimeMicros durationMicros time

generatePartition :: [NodeId] -> Gen Partition
generatePartition nodes = frequency [(1, One <$> elements nodes)]
