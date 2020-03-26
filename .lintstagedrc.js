module.exports = {
	"*.go": "gofmt -w",
	"*.dart": "dartfmt -w",
	"*.{ts,js,json,yml,yaml}": "prettier --write",
};
