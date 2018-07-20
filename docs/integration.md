# Integrating with the Arweave

## Introduction

Each node on the **Arweave** network hosts a simple lightweight REST API. This allows developers to communicate with the network via HTTP requests.

Most programming languages provide 'out of the box' functionality for making web calls and as such can simply communicate using this method.

## Transaction format

Transactions are submitted to the network via this HTTP interface and structured as JSON. Note that currently, transactions are limited to one transaction from each given wallet per block.

An example of the transaction format is below.

### Erlang

```erlang
%% A transaction, as stored in a block.
-record(tx, {
	id = <<>>, % TX UID.
	last_tx = <<>>, % Get last TX hash.
	owner = <<>>, % Public key of transaction owner.
	tags = [], % Indexable TX category identifiers.
	target = <<>>, % Address of target of the tx.
	quantity = 0, % Amount to send
	data = <<>>, % Data in transaction (if data transaction).
	signature = <<>>, % Transaction signature.
	reward = 0 % Transaction mining reward.
}).
```

### JSON

```javascript
{
	"id": "",
	"last_tx": "",
	"owner": "",
	"tags": "",
	"target": "",
	"quantity": "",
	"data": "",
	"reward": "",
	"signature": ""
}
```

### Fields

- `id` A SHA2-256 hash of the signature, based 64 URL encoded. 
- `last_tx` The ID of the last transaction made from the same address base64url encoded. If no previous transactions have been made from the address this field is set to an empty string.
- `owner` The modulus of the RSA key pair corresponding to the wallet making the transaction, base64url encoded.
- `tags` A field that allows the sender to provide further information about the transaction. Formatted as a key-value pair. Certain tag names are reserved and will be ignored if added, currently: "from", "to", "quantity" and "reward".
- `target`If making a financial transaction this field contains the wallet address of the recipient base64url encoded. If the transaction is not a financial this field is set to an empty string. A wallet address is a base64url encoded SHA256 hash of the raw unencoded RSA modulus.
- `quantity` If making a financial transaction this field contains the amount in Winston to be sent to the receiving wallet. If the transaction is not financial this field is set to the string "0". (1 AR = 1000000000000 (1e+12) Winston).
- `data` If making an archiving transaction this field contains the data to be archived base64url encoded. If the transaction is not archival this field is set to an empty string.
- `reward` This field contains the mining reward for the transaction in Winston. (1 AR = 1000000000000 (1e+12) Winston).
- `signature` The data for the signature is comprised of previous data from the rest of the transaction.

The data to be signed is a concatentation of the raw (entirely unencoded) owner, target, id, data, quantity, reward and last_tx in that order.

The signature scheme is RSA-PSS with both a data hash and Mask Generation Function (MGF) hash of SHA-256.

The psuedocode below shows this.

```
function unencode(X) 	<- Takes input X and returns the completely unencoded form
function sign(D, K)  	<- Takes data D and key K returns a signature of D signed with K

owner     <- unencode(owner)
target    <- unencode(target)
id        <- unencode(id)
data      <- unencode(data)
quantity  <- unencode(quantity)
reward    <- unencode(reward)
last_tx   <- unencode(last_tx)

signatureData <- owner + target + id + data + quantity + reward + last_tx
signature <- sign(signatureData, key)

return signature
```

Once returned the RSA-PSS signature is base64url encoded and added to the transactions JSON struct.

The transaction is now complete and ready to be submitted to the network via a POST request on the '/tx' endpoint.

## Field Size limits

Transactions must conform to certain size limits in each field. These size limits are as follows:

| Field       | Size Limit  |
| ----------- | -----------:|
| `id`        | 32 Bytes    |
| `lst_tx`    | 32 Bytes    |
| `owner`     | 512 Bytes   |
| `tags`      | 2048 Bytes  |
| `target`    | 32 Bytes    |
| `quantity`  | 21 Bytes    |
| `data`      | Not limited |
| `reward`    | 21 Bytes    |
| `signature` | 512 Bytes   |

Furthermore, at least briefly in **Arweaves** life cycle (and at the time of writing), the max possible total transaction size (unencoded, including all fields) is limited to 50mb.

## Example Archiving Transaction

```javascript
{
 	"id": "eDhZfOhEmVZV72h0Xm_AX1MEuPnqvGeeXstBbLY3Sdk",
	"last_tx": "eC8pO0aKOxkQHLLGmfLKvBQnnRlTk1uq10H8fQAATAA",
	"owner": "1Q7Rf...2x0xC",						// Partially omitted due to length
	"tags": []
	"target": "",
	"quantity": "0",
	"data": "",
	"reward": "2343181818",
	"signature": "Bgb65...7cBR4" 					// Partially omitted due to length
}
```

## Example Financial Transaction

```javascript
{
  	"id": "iwUl8_2Bc07vOCjE9Q5_VQ8KrvHZu0Rk-eq3c8bF6X8",
	"last_tx": "eDhZfOhEmVZV72h0Xm_AX1MEuPnqvGeeXstBbLY3Sdk",
	"owner": "1Q7Rf...2x0xC",						// Partially omitted due to length
	"tags":[{"Application", "app_election"}, {"Source", "Automated"}]
	"target": "f1FHKWEauF3bJYfn6i0mM5zrUfIxn8lUQHlWKUmP04M",
	"quantity": "25550000000000",
	"data": "",
	"reward": "1907348633",
	"signature": "Hg02G...cdNk8" 					// Partially omitted due to length
}
```



## Notes

> Please note that in the JSON transaction records all winston value fields (quantity and reward) are strings. This is to allow for interoperability between environments that do not accommodate arbitrary-precision arithmetic. JavaScript for instance stores all numbers as double precision floating point values and as such cannot natively express the integer number of winston. Providing these values as strings allows them to be directly loaded into most 'bignum' libraries.

> Transactions are required to contain the ID of the last transaction made by the same wallet, this value can be retrieved via hitting the '/wallet/[wallet_address]/last_tx' endpoint of any node on the network. More details regarding this endpoint can be found here in the node HTTP interface docs.

> Multiple variants of base64url encoding exist and within the Arweave network we use a specific form. The standard base64 characters '+' and '/' are replaced with '-' and  '\_' respectively, and all padding characters, '=', are stripped from the end of the encoded string.
