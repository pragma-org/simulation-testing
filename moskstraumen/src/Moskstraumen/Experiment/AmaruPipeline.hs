module Moskstraumen.Experiment.AmaruPipeline (module Moskstraumen.Experiment.AmaruPipeline) where

type Peer = String
type RawHeader = ByteString

data Point = Origin | Specific Slot HeaderHash
type Slot = Word64
type HeaderHash = ByteString

data PullEvent
  = RollForward Peer Point RawHeader
  | Rollback Peer Rollback

type Header -- Pallas

data ValidateHeaderEvent
  = Validated Peer Point
  | Rollback Point

data ValidateBlockEvent
  = Validated Point RawBlock
  | Rollback Point

type RawBlock = ByteString

type Stage state input m output

------------------------------------------------------------------------

-- crates/amaru/src/stages/pull.rs
recvHeader :: Stage () void Network PullEvent

-- crates/amaru/src/stages/consensus/header.rs
validateHeader :: Stage Store PullEvent IO (HeaderHash, Header)

-- crates/amaru-consensus/src/consensus/header_validation.rs 
-- (fn handle_roll_forward)
storeHeader :: Stage Store (HeaderHash, Header) IO ()

-- crates/amaru-consensus/src/consensus/header_validation.rs
-- (fn handle_roll_forward)
selectChain :: Stage (ChainSelector Header) Identity [ValidateHeaderEvent]

-- crates/amaru/src/stages/consensus/fetch.rs
fetchBlock :: Stage (Map Peer PeerSession) ValidateHeaderEvent IO ValidateBlockEvent

-- crates/amaru/src/stages/ledger.rs
validateBlock :: Stage () ValidateBlockEvent _ BlockValidationResult

-- Not implemented yet.
storeBlock :: Stage Store _ IO ()

-- crates/amaru/src/stages/consensus/forward_chain.rs
forwardChain :: Stage _ (NewPeer + BlockValidationResult) Network ()
