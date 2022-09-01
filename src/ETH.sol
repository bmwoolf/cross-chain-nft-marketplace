pragma solidity 0.8.16;

import {IStargateReceiver} from "./interfaces/Stargate/IStargateReceiver.sol";
import {IStargateRouter} from "./interfaces/Stargate/IStargateRouter.sol";
import {ISwapRouter} from "./interfaces/dex/ISwapRouter.sol";
import {MarketplaceEventsAndErrors} from "./interfaces/MarketplaceEventsAndErrors.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/// @title Cross-chain NFT Marketplace
/// @author bmwoolf and zksoju
/// @notice Cross Chain NFT Marketplace built on LayerZero
/// @dev Lives on Ethereum mainnet (compatible with other networks Uniswap supports)
contract MarketplaceETH is IStargateReceiver, Ownable, MarketplaceEventsAndErrors {
    /// @notice Stargate router contract
    IStargateRouter public immutable stargateRouter;

    /// @notice DEX contract for current chain (ex. Uniswap/TraderJoe)
    ISwapRouter public immutable dexRouter;

    /// @notice Wrapped native token contract for current chain, used for wrapping and unwrapping
    IWETH9 public immutable wrappedNative;

    /// @notice USDC contract
    IERC20 public immutable USDC;

    /// @notice Index for current listing
    uint256 public currentListingIndex;

    /// @notice Current chain id
    uint16 public immutable currentChainId;

    uint256 public intConstant = 10000;
    uint256 public fee = 200;

    /// @notice Maps chain ids to corresponding marketplace contract
    mapping(uint16 => bytes) public marketplaceAddresses;

    /// @notice Maps collection contract addresses to approval status
    mapping(address => bool) public approvedNFTs;

    /// @notice Maps key composed of contract address and token id to item listings
    mapping(bytes32 => ItemListing) public sellerListings;

    /// @notice Struct composed of details used for marketplace listings
    /// @param lister The address of the lister
    /// @param collectionAddress The address of the collection contract
    /// @param tokenId The token id of the NFT
    /// @param price The price of the NFT
    /// @param active The status of the listing
    struct ItemListing {
        uint256 listingId;
        address lister;
        address collectionAddress;
        uint256 tokenId;
        uint256 price;
        ListingStatus status;
    }

    /// @notice Defines possible states for the listing
    /// @param INACTIVE The listing is inactive and unable to be purchased
    /// @param ACTIVE_LOCAL The listing is active and able to be purchased only locally
    /// @param ACTIVE_CROSSCHAIN The listing is active and able to be purchased crosschain
    enum ListingStatus {
        INACTIVE,
        ACTIVE_LOCAL,
        ACTIVE_CROSSCHAIN
    }

    constructor(
        uint16 _currentChainId,
        address _stargateRouter,
        address _dexRouter,
        address _usdcAddress,
        address _wrappedNative
    ) {
        currentChainId = _currentChainId;
        stargateRouter = IStargateRouter(_stargateRouter);
        dexRouter = ISwapRouter(_dexRouter);
        USDC = IERC20(_usdcAddress);
        wrappedNative = IWETH9(_wrappedNative);
    }

    modifier onlyContract() {
        if (msg.sender != address(this)) revert NotFromContract();
        _;
    }

    /// @notice Restricts action to only the owner of the token
    /// @param collectionAddress The address of the collection contract
    /// @param tokenId The token id of the item
    modifier onlyTokenOwner(address collectionAddress, uint256 tokenId) {
        if (IERC721(collectionAddress).ownerOf(tokenId) != msg.sender)
            revert NotTokenOwner();
        _;
    }

    /// @notice Processes listing purchases initiated from cross-chain through Stargate router
    /// @param token Address of the native stable received (ex. USDC)
    /// @param amountLD Amount of token received from the router
    /// @param payload Byte data composed of seller listing key and address to receive NFT
    function sgReceive(
        uint16,
        bytes memory,
        uint256,
        address token,
        uint256 amountLD,
        bytes memory payload
    ) external override {
        if (msg.sender != address(stargateRouter)) revert NotFromRouter();

        (address collectionAddress, uint256 tokenId, address toAddress) = abi
            .decode(payload, (address, uint256, address));

        ItemListing memory listing = sellerListings[
            keccak256(abi.encodePacked(collectionAddress, tokenId))
        ];

        try
            this._executeBuy(
                amountLD,
                listing,
                toAddress,
                collectionAddress,
                tokenId
            )
        {
            //do nothing
        } catch {
            // if buy fails, refund the buyer in stablecoin: "we swapped it to stables for you"
            USDC.transfer(toAddress, amountLD); //refund buyer USDC if buy fails
            emit SwapFailRefund(
                listing.listingId,
                currentChainId,
                toAddress,
                listing.price,
                amountLD
            );
        }
    }

    /// @notice Internal function used to execute a buy originating from cross-chain through Stargate router
    /// @param amount Amount of stables to swap for wrapped native
    /// @param listing The listing of the NFT
    /// @param buyer The address to receive the NFT
    /// @param collectionAddress The address of the collection contract
    /// @param tokenId The token id of the NFT
    function _executeBuy(
        uint256 amount,
        ItemListing calldata listing,
        address buyer,
        address collectionAddress,
        uint256 tokenId
    ) external onlyContract {
        if (listing.status != ListingStatus.ACTIVE_CROSSCHAIN)
            revert NotActiveGlobalListing();

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: address(USDC),
                tokenOut: address(wrappedNative),
                fee: 3000,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        uint256 amountOut = dexRouter.exactInputSingle(params);

        uint256 listingPriceWithTolerance = listing.price -
            ((listing.price * 100) / intConstant);

        if (amountOut < listingPriceWithTolerance) {
            // refund the buyer in full with native token
            // dexRouter.unwrapWETH9(amountOut, buyer);
            _unwrapNative(amountOut, buyer);

            emit PriceFailRefund(
                listing.listingId,
                currentChainId,
                buyer,
                listing.price,
                amountOut
            );
        } else {
            // keep marketplace fees in wrapped native
            uint256 sellerFee = (amountOut * fee) / intConstant;
            amountOut = amountOut - sellerFee;

            // pay seller, transfer owner, delist nft
            // TODO: handle potential error case
            _unwrapNative(amountOut, listing.lister); // pay the seller

            IERC721(collectionAddress).transferFrom(
                listing.lister,
                buyer,
                tokenId
            );
            _delist(collectionAddress, tokenId);

            emit ItemSold(
                listing.listingId,
                currentChainId,
                listing.lister,
                buyer,
                collectionAddress,
                tokenId,
                listing.price,
                amountOut
            );
        }
    }

    function _unwrapNative(uint256 amount, address recipient) internal {
        uint256 balance = wrappedNative.balanceOf(address(this));
        require(balance >= amount, "Insufficient wrapped native");

        if (balance > 0) {
            wrappedNative.withdraw(amount);
            (bool success, ) = recipient.call{value: amount}("");
            if (!success) revert FundsTransferFailure();
        }
    }

    /// @notice Purchases NFT from the marketplace on a different chain than the buyer's token
    /// @param chainId The chain id associated with the marketplace to purchase from
    /// @param collectionAddress The address of the collection contract
    /// @param tokenId The token id of the NFT
    /// @param toAddr The address to receive the NFT
    /// @param nativePrice Amount of native token you need in order to buy in the foreign token
    /// (ex. How much ETH you need to buy listing on Avalanche in AVAX?)
    function buyCrosschain(
        uint16 chainId,
        address collectionAddress,
        uint256 tokenId,
        address toAddr,
        uint256 nativePrice
    ) external payable {
        bytes memory destAddr = marketplaceAddresses[chainId];

        IStargateRouter.lzTxObj memory lzParams = IStargateRouter.lzTxObj(
            500000,
            0,
            "0x"
        );

        bytes memory payload = abi.encode(collectionAddress, tokenId, toAddr);

        uint256 fee = quoteLayerZeroFee(chainId, payload, lzParams);

        if (msg.value < fee + nativePrice) revert InsufficientFunds();
        uint256 amountWithFee = nativePrice + fee;

        uint256 amountStable = _swapForPurchase(nativePrice);

        stargateRouter.swap{value: fee}(
            chainId,
            1,
            1,
            payable(msg.sender),
            amountStable,
            0,
            lzParams,
            destAddr,
            payload
        );
    }

    /// @notice Quotes transaction fees to supply to use Stargate
    /// @param chainId The chain id to send the LayerZero message to
    /// @param payload The data supplied to the LayerZero message
    /// @param lzParams Additional configuration to supply to LayerZero
    function quoteLayerZeroFee(
        uint16 chainId,
        bytes memory payload,
        IStargateRouter.lzTxObj memory lzParams
    ) public view returns (uint256) {
        (uint256 fee, ) = stargateRouter.quoteLayerZeroFee(
            chainId,
            1,
            marketplaceAddresses[chainId],
            payload,
            lzParams
        );

        return fee;
    }

    /// @notice Swap native wrapped tokens (ex. WETH) for stables (ex. USDC) using local DEX
    /// @dev Stable used to bridge cross-chain with Stargate
    /// @param amount Amount of native wrapped tokens to swap for stables
    function _swapForPurchase(uint256 amount) internal returns (uint256) {
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: address(wrappedNative),
                tokenOut: address(USDC),
                fee: 3000,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        dexRouter.exactInputSingle{value: amount}(params);
        return USDC.balanceOf(address(this));
    }

    /// @notice Purchase a same-chain listing in native tokens
    /// @param collectionAddress The address of the collection contract
    /// @param tokenId The token id of the NFT
    function buyLocal(
        address collectionAddress,
        uint256 tokenId,
        address
    ) external payable {
        ItemListing memory listing = sellerListings[
            keccak256(abi.encodePacked(collectionAddress, tokenId))
        ];

        if (
            listing.status != ListingStatus.ACTIVE_LOCAL &&
            listing.status != ListingStatus.ACTIVE_CROSSCHAIN
        ) revert NotActiveLocalListing();
        if (listing.price > msg.value) revert InsufficientFunds();
        if (listing.price < msg.value) revert ExcessFunds();

        uint256 listingPriceMinusFee = listing.price -
            (fee * listing.price) /
            intConstant;

        (bool success, ) = listing.lister.call{value: listingPriceMinusFee}("");
        if (!success) revert FundsTransferFailure();

        IERC721(collectionAddress).transferFrom(
            listing.lister,
            msg.sender,
            tokenId
        );
        _delist(collectionAddress, tokenId);
        emit ItemSold(
            listing.listingId,
            currentChainId,
            listing.lister,
            msg.sender,
            collectionAddress,
            tokenId,
            listing.price,
            listingPriceMinusFee
        );
    }

    /// @notice List an NFT for sale
    /// @param collectionAddress The address of the collection contract
    /// @param tokenId The token id of the NFT
    /// @param nativePrice The price of the NFT in native tokens
    function listItem(
        address collectionAddress,
        uint256 tokenId,
        uint256 nativePrice,
        bool isCrossChain
    ) external onlyTokenOwner(collectionAddress, tokenId) {
        if (!approvedNFTs[collectionAddress]) revert NotApprovedNFT();

        bytes32 key = keccak256(abi.encodePacked(collectionAddress, tokenId));
        ItemListing memory listing = ItemListing(
            currentListingIndex,
            msg.sender,
            collectionAddress,
            tokenId,
            nativePrice,
            isCrossChain
                ? ListingStatus.ACTIVE_CROSSCHAIN
                : ListingStatus.ACTIVE_LOCAL
        );
        sellerListings[key] = listing;

        currentListingIndex++;

        emit ItemListed(
            listing.listingId,
            currentChainId,
            msg.sender,
            collectionAddress,
            tokenId,
            nativePrice,
            isCrossChain
        );
    }

    /// @notice Deactivates NFT listing on-chain
    /// @param collectionAddress The address of the collection contract
    /// @param tokenId The token id of the NFT
    function delistItem(address collectionAddress, uint256 tokenId)
        external
        onlyTokenOwner(collectionAddress, tokenId)
    {
        bytes32 key = keccak256(abi.encodePacked(collectionAddress, tokenId));

        ItemListing memory listing = sellerListings[key];

        listing.status = ListingStatus.INACTIVE;

        sellerListings[key] = listing;

        emit ItemDelisted(
            listing.listingId,
            currentChainId,
            sellerListings[key].lister
        );
    }

    /// @notice Internal function for deactivating a listing
    function _delist(address collectionAddress, uint256 tokenId) internal {
        bytes32 key = keccak256(abi.encodePacked(collectionAddress, tokenId));
        sellerListings[key].status = ListingStatus.INACTIVE;
    }

    /// @notice Approves routers to spend this contracts USDC balance
    function approveRouters() public onlyOwner {
        USDC.approve(address(stargateRouter), 2**256 - 1);
        USDC.approve(address(dexRouter), 2**256 - 1);
    }

    /// @notice Configures the other marketplace addresses and their respective chain ids
    /// @param chainId The chain id associated with the marketplace
    /// @param marketplaceAddress The address of the marketplace
    function setMarketplace(uint16 chainId, bytes calldata marketplaceAddress)
        external
        onlyOwner
    {
        marketplaceAddresses[chainId] = marketplaceAddress;
    }

    /// @notice Sets the fee for the marketplace
    /// @param newFee New fee for the marketplace
    function setFee(uint256 newFee) external onlyOwner {
        fee = newFee;
    }

    /// @notice Approves an NFT contract, used to curate collections
    /// @param contractAddress The address of the NFT contract
    function addNFTContract(address contractAddress) external onlyOwner {
        approvedNFTs[contractAddress] = true;
    }

    /// @notice Removes approval for an NFT contract, used to curate collections
    /// @param contractAddress The address of the NFT contract
    function removeNFTContract(address contractAddress) external onlyOwner {
        delete approvedNFTs[contractAddress];
    }

    /// @notice Modifies price of an existing listing
    /// @param collectionAddress The address of the collection contract
    /// @param tokenId The token id of the NFT
    /// @param newPrice The new price of the NFT
    function editPrice(
        address collectionAddress,
        uint256 tokenId,
        uint256 newPrice
    ) external onlyTokenOwner(collectionAddress, tokenId) {
        bytes32 key = keccak256(abi.encodePacked(collectionAddress, tokenId));

        ItemListing memory listing = sellerListings[key];

        if (msg.sender != listing.lister) revert NotListingOwner();
        if (sellerListings[key].collectionAddress == address(0))
            revert NonexistentListing();

        uint256 oldPrice = sellerListings[key].price;
        listing.price = newPrice;

        sellerListings[key] = listing;

        emit PriceChanged(
            listing.listingId,
            currentChainId,
            msg.sender,
            oldPrice,
            newPrice
        );
    }

    /// @notice Retrieves listing information for a specific key
    /// @param key The key to get the associated listing for
    function getSellerListings(bytes32 key)
        external
        view
        returns (
            uint256 listingId,
            address lister,
            address collectionAddress,
            uint256 tokenId,
            uint256 price,
            ListingStatus status
        )
    {
        ItemListing memory listing = sellerListings[key];
        listingId = listing.listingId;
        lister = listing.lister;
        collectionAddress = listing.collectionAddress;
        tokenId = listing.tokenId;
        price = listing.price;
        status = listing.status;
    }

    receive() external payable {}
}
