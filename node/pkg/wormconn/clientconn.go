package wormconn

import (
	"context"
	"encoding/hex"
	"fmt"
	"sync"

	// bookkeepingmodule "github.com/certusone/wormhole/wormchain/x/bookkeeping"
	// tokenbridgemodule "github.com/certusone/wormhole/wormchain/x/tokenbridge"
	// wormholemodule "github.com/wormhole-foundation/wormhole/wormchain/x/wormhole"
	// wormholeclient "github.com/wormhole-foundation/wormhole/wormchain/x/wormhole/client"

	cryptotypes "github.com/cosmos/cosmos-sdk/crypto/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	sdktx "github.com/cosmos/cosmos-sdk/types/tx"
	"github.com/cosmos/cosmos-sdk/x/auth"

	"github.com/cosmos/cosmos-sdk/x/auth/vesting"
	"github.com/cosmos/cosmos-sdk/x/bank"
	"github.com/cosmos/cosmos-sdk/x/capability"

	"github.com/cosmos/cosmos-sdk/x/crisis"
	distr "github.com/cosmos/cosmos-sdk/x/distribution"

	"github.com/cosmos/cosmos-sdk/x/evidence"
	feegrantmodule "github.com/cosmos/cosmos-sdk/x/feegrant/module"
	"github.com/cosmos/cosmos-sdk/x/genutil"
	"github.com/cosmos/cosmos-sdk/x/mint"

	"github.com/cosmos/cosmos-sdk/x/params"
	"github.com/cosmos/cosmos-sdk/x/slashing"
	"github.com/cosmos/cosmos-sdk/x/staking"

	"github.com/cosmos/cosmos-sdk/x/upgrade"

	"github.com/btcsuite/btcutil/bech32"

	// These are causing a duplicate error panic on start up.
	// "github.com/cosmos/ibc-go/modules/apps/transfer"
	// ibc "github.com/cosmos/ibc-go/modules/core"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// This is copied from wormhole_chain/app/app.go because the cosmos-sdk version
// used by wormhole-chain conflicts with the one used by terra so we can't use
// it directly.
// func getGovProposalHandlers() []govclient.ProposalHandler {
// 	var govProposalHandlers []govclient.ProposalHandler

// 	govProposalHandlers = append(govProposalHandlers,
// 		paramsclient.ProposalHandler,
// 		distrclient.ProposalHandler,
// 		upgradeclient.ProposalHandler,
// 		upgradeclient.CancelProposalHandler,
// 		wormholeclient.GuardianSetUpdateProposalHandler,
// 		wormholeclient.WormholeGovernanceMessageProposalHandler,
// 	)

// 	return govProposalHandlers
// }

// This is copied from wormhole_chain/app/app.go because the cosmos-sdk version
// used by wormhole-chain conflicts with the one used by terra so we can't use
// it directly.
var moduleBasics = module.NewBasicManager(
	auth.AppModuleBasic{},
	genutil.AppModuleBasic{},
	bank.AppModuleBasic{},
	capability.AppModuleBasic{},
	staking.AppModuleBasic{},
	mint.AppModuleBasic{},
	distr.AppModuleBasic{},
	// gov.NewAppModuleBasic(getGovProposalHandlers()...),
	params.AppModuleBasic{},
	crisis.AppModuleBasic{},
	slashing.AppModuleBasic{},
	feegrantmodule.AppModuleBasic{},
	// ibc.AppModuleBasic{},
	upgrade.AppModuleBasic{},
	evidence.AppModuleBasic{},
	// transfer.AppModuleBasic{},
	vesting.AppModuleBasic{},
	// wormholemodule.AppModuleBasic{},
	// tokenbridgemodule.AppModuleBasic{},
	// bookkeepingmodule.AppModuleBasic{},
)

// ClienConn represents a connection to a wormhole-chain endpoint, encapsulating
// interactions with the chain.
//
// Once a connection is established, users must call ClientConn.Close to
// terminate the connection and free up resources.
//
// For semantics around ctx use and closing/ending streaming RPCs, please refer
// to https://godoc.org/google.golang.org/grpc#ClientConn.NewStream.
type ClientConn struct {
	c          *grpc.ClientConn
	encCfg     EncodingConfig
	privateKey cryptotypes.PrivKey
	publicKey  string
	mutex      sync.Mutex // Protects the account / sequence number
}

// NewConn creates a new connection to the wormhole-chain instance at `target`.
func NewConn(ctx context.Context, target string, privateKey cryptotypes.PrivKey) (*ClientConn, error) {
	c, err := grpc.DialContext(
		ctx,
		target,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		return nil, err
	}

	encCfg := MakeEncodingConfig(moduleBasics)

	publicKey, err := generatePublicKey(privateKey)
	if err != nil {
		return nil, err
	}

	return &ClientConn{c: c, encCfg: encCfg, privateKey: privateKey, publicKey: publicKey}, nil
}

func (c *ClientConn) PublicKey() string {
	return c.publicKey
}

// Close terminates the connection and frees up resources.
func (c *ClientConn) Close() {
	c.mutex.Lock()
	defer c.mutex.Unlock()
	c.c.Close()
}

func (c *ClientConn) BroadcastTxResponseToString(txResp *sdktx.BroadcastTxResponse) (string, error) {
	out, err := c.encCfg.Marshaler.MarshalJSON(txResp)
	if err != nil {
		return "", err
	}

	return string(out), nil
}

// generatePublicKey creates the public key from the private key. It is based on https://pkg.go.dev/github.com/btcsuite/btcutil/bech32#Encode
func generatePublicKey(privateKey cryptotypes.PrivKey) (string, error) {
	data, err := hex.DecodeString(privateKey.PubKey().Address().String())
	if err != nil {
		return "", fmt.Errorf("failed to generate public key, failed to hex decode string: %w", err)
	}

	conv, err := bech32.ConvertBits(data, 8, 5, true)
	if err != nil {
		return "", fmt.Errorf("failed to generate public key, failed to convert bits: %w", err)
	}

	encoded, err := bech32.Encode("wormhole", conv)
	if err != nil {
		return "", fmt.Errorf("failed to generate public key, bech32 encode failed: %w", err)
	}

	return encoded, nil
}