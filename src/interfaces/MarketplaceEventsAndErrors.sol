pragma solidity 0.8.16;

abstract contract MarketplaceEventsAndErrors {
    /// @dev Event is fired when a listing is closed and token is sold on the marketplace.
    /// @param listingId The id of the listing.
    /// @param chainId The chain id that action took place.
    /// @param seller The seller and old owner of the token.
    /// @param buyer The buyer and new owner of the token.
    /// @param collectionAddress The address that the token is from.
    /// @param tokenId The id of the token.
    /// @param price The price of the listing.
    /// @param amountReceived The amount of tokens received.
    event ItemSold(
        uint256 listingId,
        uint16 chainId,
        address indexed seller,
        address indexed buyer,
        address collectionAddress,
        uint256 tokenId,
        uint256 price,
        uint256 amountReceived
    );

    /// @dev Event is fired when a listing is opened.
    /// @param listingId The id of the listing.
    /// @param chainId The chain id that action took place.
    /// @param seller The seller and old owner of the token.
    /// @param collectionAddress The address that the token is from.
    /// @param tokenId The id of the token.
    /// @param price The price of the listing.
    event ItemListed(
        uint256 listingId,
        uint16 chainId,
        address indexed seller,
        address collectionAddress,
        uint256 tokenId,
        uint256 price,
        bool isCrossChain
    );

    /// @dev Event is fired when a listing is delisted.
    /// @param listingId The id of the listing.
    /// @param chainId The chain id that action took place.
    /// @param seller The seller and lister of the token.
    event ItemDelisted(
        uint256 listingId,
        uint16 chainId,
        address indexed seller
    );

    /// @dev Event is fired when execute buy fails and buyer is refunded.
    /// @param listingId The id of the listing.
    /// @param chainId The chain id that action took place.
    /// @param buyer The buyer and receiver of the refund.
    /// @param price The price of the item.
    /// @param refundAmount The amount refunded to buyer in stable.
    event SwapFailRefund(
        uint256 listingId,
        uint16 chainId,
        address indexed buyer,
        uint256 price,
        uint256 refundAmount
    );

    /// @dev Event is fired when the amount after passing through Stargate
    /// and local DEX is insufficient to make the purchase. The buyer
    /// will then receive a refund in the native token on the chain
    /// the listing is live on.
    /// @param listingId The id of the listing.
    /// @param chainId The chain id that action took place.
    /// @param buyer The buyer and receiver of the refund.
    /// @param price The price of the item.
    /// @param refundAmount The amount refunded to buyer in native tokens.
    event PriceFailRefund(
        uint256 listingId,
        uint16 chainId,
        address indexed buyer,
        uint256 price,
        uint256 refundAmount
    );

    /// @dev Event is fired when the price of a listing is changed.
    /// @param listingId The id of the listing.
    /// @param chainId The chain id that action took place.
    /// @param seller The seller and old owner of the token.
    /// @param oldPrice The price the listing is changed from.
    /// @param newPrice The price the listing is changed to.
    event PriceChanged(
        uint256 listingId,
        uint16 chainId,
        address indexed seller,
        uint256 oldPrice,
        uint256 newPrice
    );

    /// @dev Revert when message is received from a non-authorized stargateRouter address.
    error NotFromRouter();

    /// @dev Revert when user is attempting an action that requires token ownership.
    error NotTokenOwner();

    /// @dev Revert when user is attempting an action that requires listing ownership.
    error NotListingOwner();

    /// @dev Revert when user is attempting an action that requires approval of the contract address.
    /// associated with the token
    error NotApprovedNFT();

    /// @dev Revert when action is attempted not from the contract.
    error NotFromContract();

    /// @dev Revert when funds fail to transfer to buyer.
    error FundsTransferFailure();

    /// @dev Revert when user is attempting to edit a listing that is non-existent.
    error NonexistentListing();

    /// @dev Revert when user is attempting an action that requires listing to be active locally.
    error NotActiveLocalListing();

    /// @dev Revert when user is attempting an action that requires listing to be active locally.
    error NotActiveGlobalListing();

    /// @dev Revert when user is attempting to purchase a listing for a price that is less than the current price.
    error InsufficientFunds();

    /// @dev Revert when user is attempting to purchase a listing for a price that is greater than the current price.
    error ExcessFunds();
}
