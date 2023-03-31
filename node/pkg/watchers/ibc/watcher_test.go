package ibc

import (
	"encoding/hex"
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/tidwall/gjson"
	"go.uber.org/zap"

	"github.com/wormhole-foundation/wormhole/sdk/vaa"
)

func TestParseIbcReceivePublishEvent(t *testing.T) {
	logger := zap.NewNop()

	eventJson := `{"type": "wasm","attributes": [` +
		`{"key": "X2NvbnRyYWN0X2FkZHJlc3M=","value": "d29ybWhvbGUxbmM1dGF0YWZ2NmV5cTdsbGtyMmd2NTBmZjllMjJtbmY3MHFnamx2NzM3a3RtdDRlc3dycTBrZGhjag==","index": true},` +
		`{"key": "YWN0aW9u", "value": "cmVjZWl2ZV9wdWJsaXNo", "index": true},` +
		`{"key": "Y2hhbm5lbF9pZA==", "value": "Y2hhbm5lbC0w", "index": true},` +
		`{"key": "bWVzc2FnZS5tZXNzYWdl","value": "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwNA==","index": true},` +
		`{"key": "bWVzc2FnZS5zZW5kZXI=","value": "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMzU3NDMwNzQ5NTZjNzEwODAwZTgzMTk4MDExY2NiZDRkZGYxNTU2ZA==","index": true},` +
		`{ "key": "bWVzc2FnZS5jaGFpbl9pZA==", "value": "MTg=", "index": true },` +
		`{ "key": "bWVzc2FnZS5ub25jZQ==", "value": "MQ==", "index": true },` +
		`{ "key": "bWVzc2FnZS5zZXF1ZW5jZQ==", "value": "Mg==", "index": true },` +
		`{"key": "bWVzc2FnZS5ibG9ja190aW1l","value": "MTY4MDA5OTgxNA==","index": true},` +
		`{"key": "bWVzc2FnZS5ibG9ja19oZWlnaHQ=","value": "MjYxMw==","index": true}` +
		`]}`

	require.Equal(t, true, gjson.Valid(eventJson))
	event := gjson.Parse(eventJson)

	contractAddress := "wormhole1nc5tatafv6eyq7llkr2gv50ff9e22mnf70qgjlv737ktmt4eswrq0kdhcj"

	evt, err := parseEvent[ibcReceivePublishEvent](logger, contractAddress, "receive_publish", event)
	require.NoError(t, err)
	require.NotNil(t, evt)

	expectedSender, err := vaa.StringToAddress("00000000000000000000000035743074956c710800e83198011ccbd4ddf1556d")
	require.NoError(t, err)

	expectedPayload, err := hex.DecodeString("0000000000000000000000000000000000000000000000000000000000000004")
	require.NoError(t, err)

	expectedResult := ibcReceivePublishEvent{
		ChannelID:      "channel-0",
		EmitterAddress: expectedSender,
		EmitterChain:   vaa.ChainIDTerra2,
		Nonce:          1,
		Sequence:       2,
		Timestamp:      time.Unix(1680099814, 0),
		Payload:        expectedPayload,
	}
	assert.Equal(t, expectedResult, *evt)
}

func TestParseEventOfWrongType(t *testing.T) {
	logger := zap.NewNop()

	eventJson := `{"type": "hello","attributes": [` +
		`{"key": "X2NvbnRyYWN0X2FkZHJlc3M=","value": "d29ybWhvbGUxbmM1dGF0YWZ2NmV5cTdsbGtyMmd2NTBmZjllMjJtbmY3MHFnamx2NzM3a3RtdDRlc3dycTBrZGhjag==","index": true},` +
		`{"key": "YWN0aW9u", "value": "cmVjZWl2ZV9wdWJsaXNo", "index": true},` +
		`{"key": "Y2hhbm5lbF9pZA==", "value": "Y2hhbm5lbC0w", "index": true},` +
		`{"key": "bWVzc2FnZS5tZXNzYWdl","value": "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwNA==","index": true},` +
		`{"key": "bWVzc2FnZS5zZW5kZXI=","value": "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMzU3NDMwNzQ5NTZjNzEwODAwZTgzMTk4MDExY2NiZDRkZGYxNTU2ZA==","index": true},` +
		`{ "key": "bWVzc2FnZS5jaGFpbl9pZA==", "value": "MTg=", "index": true },` +
		`{ "key": "bWVzc2FnZS5ub25jZQ==", "value": "MQ==", "index": true },` +
		`{ "key": "bWVzc2FnZS5zZXF1ZW5jZQ==", "value": "Mg==", "index": true },` +
		`{"key": "bWVzc2FnZS5ibG9ja190aW1l","value": "MTY4MDA5OTgxNA==","index": true},` +
		`{"key": "bWVzc2FnZS5ibG9ja19oZWlnaHQ=","value": "MjYxMw==","index": true}` +
		`]}`

	require.Equal(t, true, gjson.Valid(eventJson))
	event := gjson.Parse(eventJson)

	contractAddress := "wormhole1nc5tatafv6eyq7llkr2gv50ff9e22mnf70qgjlv737ktmt4eswrq0kdhcj"

	evt, err := parseEvent[ibcReceivePublishEvent](logger, contractAddress, "receive_publish", event)
	require.NoError(t, err)
	assert.Nil(t, evt)
}

func TestParseEventForWrongContract(t *testing.T) {
	logger := zap.NewNop()

	eventJson := `{"type": "wasm","attributes": [` +
		`{"key": "X2NvbnRyYWN0X2FkZHJlc3M=","value": "d29ybWhvbGUxbmM1dGF0YWZ2NmV5cTdsbGtyMmd2NTBmZjllMjJtbmY3MHFnamx2NzM3a3RtdDRlc3dycTBrZGhjag==","index": true},` +
		`{"key": "YWN0aW9u", "value": "cmVjZWl2ZV9wdWJsaXNo", "index": true},` +
		`{"key": "Y2hhbm5lbF9pZA==", "value": "Y2hhbm5lbC0w", "index": true},` +
		`{"key": "bWVzc2FnZS5tZXNzYWdl","value": "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwNA==","index": true},` +
		`{"key": "bWVzc2FnZS5zZW5kZXI=","value": "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMzU3NDMwNzQ5NTZjNzEwODAwZTgzMTk4MDExY2NiZDRkZGYxNTU2ZA==","index": true},` +
		`{ "key": "bWVzc2FnZS5jaGFpbl9pZA==", "value": "MTg=", "index": true },` +
		`{ "key": "bWVzc2FnZS5ub25jZQ==", "value": "MQ==", "index": true },` +
		`{ "key": "bWVzc2FnZS5zZXF1ZW5jZQ==", "value": "Mg==", "index": true },` +
		`{"key": "bWVzc2FnZS5ibG9ja190aW1l","value": "MTY4MDA5OTgxNA==","index": true},` +
		`{"key": "bWVzc2FnZS5ibG9ja19oZWlnaHQ=","value": "MjYxMw==","index": true}` +
		`]}`

	require.Equal(t, true, gjson.Valid(eventJson))
	event := gjson.Parse(eventJson)

	contractAddress := "someOtherContract"

	evt, err := parseEvent[ibcReceivePublishEvent](logger, contractAddress, "receive_publish", event)
	require.NoError(t, err)
	assert.Nil(t, evt)
}

func TestParseEventForWrongAction(t *testing.T) {
	logger := zap.NewNop()

	eventJson := `{"type": "wasm","attributes": [` +
		`{"key": "X2NvbnRyYWN0X2FkZHJlc3M=","value": "d29ybWhvbGUxbmM1dGF0YWZ2NmV5cTdsbGtyMmd2NTBmZjllMjJtbmY3MHFnamx2NzM3a3RtdDRlc3dycTBrZGhjag==","index": true},` +
		`{"key": "YWN0aW9u", "value": "cmVjZWl2ZV9wa3Q=", "index": true},` + // Changed action value to "receive_pkt"
		`{"key": "Y2hhbm5lbF9pZA==", "value": "Y2hhbm5lbC0w", "index": true},` +
		`{"key": "bWVzc2FnZS5tZXNzYWdl","value": "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwNA==","index": true},` +
		`{"key": "bWVzc2FnZS5zZW5kZXI=","value": "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMzU3NDMwNzQ5NTZjNzEwODAwZTgzMTk4MDExY2NiZDRkZGYxNTU2ZA==","index": true},` +
		`{ "key": "bWVzc2FnZS5jaGFpbl9pZA==", "value": "MTg=", "index": true },` +
		`{ "key": "bWVzc2FnZS5ub25jZQ==", "value": "MQ==", "index": true },` +
		`{ "key": "bWVzc2FnZS5zZXF1ZW5jZQ==", "value": "Mg==", "index": true },` +
		`{"key": "bWVzc2FnZS5ibG9ja190aW1l","value": "MTY4MDA5OTgxNA==","index": true},` +
		`{"key": "bWVzc2FnZS5ibG9ja19oZWlnaHQ=","value": "MjYxMw==","index": true}` +
		`]}`

	require.Equal(t, true, gjson.Valid(eventJson))
	event := gjson.Parse(eventJson)

	contractAddress := "wormhole1nc5tatafv6eyq7llkr2gv50ff9e22mnf70qgjlv737ktmt4eswrq0kdhcj"

	evt, err := parseEvent[ibcReceivePublishEvent](logger, contractAddress, "receive_publish", event)
	require.NoError(t, err)
	assert.Nil(t, evt)
}

func TestParseEventForNoContractSpecified(t *testing.T) {
	logger := zap.NewNop()

	eventJson := `{"type": "wasm","attributes": [` +
		// No contract specified
		`{"key": "YWN0aW9u", "value": "cmVjZWl2ZV9wdWJsaXNo", "index": true},` +
		`{"key": "Y2hhbm5lbF9pZA==", "value": "Y2hhbm5lbC0w", "index": true},` +
		`{"key": "bWVzc2FnZS5tZXNzYWdl","value": "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwNA==","index": true},` +
		`{"key": "bWVzc2FnZS5zZW5kZXI=","value": "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMzU3NDMwNzQ5NTZjNzEwODAwZTgzMTk4MDExY2NiZDRkZGYxNTU2ZA==","index": true},` +
		`{ "key": "bWVzc2FnZS5jaGFpbl9pZA==", "value": "MTg=", "index": true },` +
		`{ "key": "bWVzc2FnZS5ub25jZQ==", "value": "MQ==", "index": true },` +
		`{ "key": "bWVzc2FnZS5zZXF1ZW5jZQ==", "value": "Mg==", "index": true },` +
		`{"key": "bWVzc2FnZS5ibG9ja190aW1l","value": "MTY4MDA5OTgxNA==","index": true},` +
		`{"key": "bWVzc2FnZS5ibG9ja19oZWlnaHQ=","value": "MjYxMw==","index": true}` +
		`]}`

	require.Equal(t, true, gjson.Valid(eventJson))
	event := gjson.Parse(eventJson)

	contractAddress := "wormhole1nc5tatafv6eyq7llkr2gv50ff9e22mnf70qgjlv737ktmt4eswrq0kdhcj"

	evt, err := parseEvent[ibcReceivePublishEvent](logger, contractAddress, "receive_publish", event)
	require.NoError(t, err)
	assert.Nil(t, evt)
}

func TestParseEventForNoActionSpecified(t *testing.T) {
	logger := zap.NewNop()

	eventJson := `{"type": "wasm","attributes": [` +
		`{"key": "X2NvbnRyYWN0X2FkZHJlc3M=","value": "d29ybWhvbGUxbmM1dGF0YWZ2NmV5cTdsbGtyMmd2NTBmZjllMjJtbmY3MHFnamx2NzM3a3RtdDRlc3dycTBrZGhjag==","index": true},` +
		// No action specified
		`{"key": "Y2hhbm5lbF9pZA==", "value": "Y2hhbm5lbC0w", "index": true},` +
		`{"key": "bWVzc2FnZS5tZXNzYWdl","value": "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwNA==","index": true},` +
		`{"key": "bWVzc2FnZS5zZW5kZXI=","value": "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMzU3NDMwNzQ5NTZjNzEwODAwZTgzMTk4MDExY2NiZDRkZGYxNTU2ZA==","index": true},` +
		`{ "key": "bWVzc2FnZS5jaGFpbl9pZA==", "value": "MTg=", "index": true },` +
		`{ "key": "bWVzc2FnZS5ub25jZQ==", "value": "MQ==", "index": true },` +
		`{ "key": "bWVzc2FnZS5zZXF1ZW5jZQ==", "value": "Mg==", "index": true },` +
		`{"key": "bWVzc2FnZS5ibG9ja190aW1l","value": "MTY4MDA5OTgxNA==","index": true},` +
		`{"key": "bWVzc2FnZS5ibG9ja19oZWlnaHQ=","value": "MjYxMw==","index": true}` +
		`]}`

	require.Equal(t, true, gjson.Valid(eventJson))
	event := gjson.Parse(eventJson)

	contractAddress := "wormhole1nc5tatafv6eyq7llkr2gv50ff9e22mnf70qgjlv737ktmt4eswrq0kdhcj"

	evt, err := parseEvent[ibcReceivePublishEvent](logger, contractAddress, "receive_publish", event)
	require.NoError(t, err)
	assert.Nil(t, evt)
}

func TestParseChannelConfig(t *testing.T) {
	var channels1 = []ConnectionConfigEntry{ConnectionConfigEntry{ChainID: vaa.ChainIDTerra2, ConnID: "connection-0"}, ConnectionConfigEntry{ChainID: vaa.ChainIDInjective, ConnID: "connection-1"}}
	_, err := json.Marshal(channels1)
	require.NoError(t, err)

	channelsJson := []byte(`[{"ChainID":18,"ConnID":"connection-0"},{"ChainID":19,"ConnID":"connection-1"}]`)

	var channels2 []ConnectionConfigEntry
	err = json.Unmarshal(channelsJson, &channels2)
	require.NoError(t, err)
	assert.Equal(t, channels1, channels2)
}

func TestParseConvertUrlToTendermint(t *testing.T) {
	expectedResult := "http://wormchain:26657"

	result, err := ConvertUrlToTendermint(expectedResult)
	require.NoError(t, err)
	assert.Equal(t, expectedResult, result)

	result, err = ConvertUrlToTendermint("ws://wormchain:26657")
	require.NoError(t, err)
	assert.Equal(t, expectedResult, result)

	result, err = ConvertUrlToTendermint("ws://wormchain:26657/websocket")
	require.NoError(t, err)
	assert.Equal(t, expectedResult, result)
}

func TestParseIbcChannelQueryResults(t *testing.T) {
	connJson := []byte(`
	{
		"channel": {
		  "state": "STATE_OPEN",
		  "ordering": "ORDER_UNORDERED",
		  "counterparty": {
			"port_id": "wasm.terra14hj2tavq8fpesdwxxcu44rty3hh90vhujrvcmstl4zr3txmfvw9ssrc8au",
			"channel_id": "channel-0"
		  },
		  "connection_hops": [
			"connection-0"
		  ],
		  "version": "ibc-wormhole-v1"
		},
		"proof": null,
		"proof_height": {
		  "revision_number": "0",
		  "revision_height": "90"
		}
	  }
	  `)

	var result ibcChannelQueryResults
	err := json.Unmarshal(connJson, &result)
	require.NoError(t, err)
	require.Equal(t, 1, len(result.Channel.ConnectionHops))
	assert.Equal(t, "connection-0", result.Channel.ConnectionHops[0])
}

func TestParseIbcChannelQueryResultsMultipleHops(t *testing.T) {
	connJson := []byte(`
	{
		"channel": {
		  "state": "STATE_OPEN",
		  "ordering": "ORDER_UNORDERED",
		  "counterparty": {
			"port_id": "wasm.terra14hj2tavq8fpesdwxxcu44rty3hh90vhujrvcmstl4zr3txmfvw9ssrc8au",
			"channel_id": "channel-0"
		  },
		  "connection_hops": [
			"connection-0",
			"connection-42"
		  ],
		  "version": "ibc-wormhole-v1"
		},
		"proof": null,
		"proof_height": {
		  "revision_number": "0",
		  "revision_height": "90"
		}
	  }
	  `)

	var result ibcChannelQueryResults
	err := json.Unmarshal(connJson, &result)
	require.NoError(t, err)
	require.Equal(t, 2, len(result.Channel.ConnectionHops))
	assert.Equal(t, "connection-0", result.Channel.ConnectionHops[0])
}
