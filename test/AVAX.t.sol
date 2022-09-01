// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.16;

import {AVAX} from "../src/AVAX.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {MarketplaceEventsAndErrors} from "../src/interfaces/MarketplaceEventsAndErrors.sol";
import {ISwapRouter} from "../src/interfaces/dex/ISwapRouter.sol";
import {IStargateRouter} from "../src/interfaces/Stargate/IStargateRouter.sol";
import {IWETH9 as IWAVAX} from "../src/interfaces/IWETH9.sol";

import {IERC721} from "@openzeppelin/contracts/interfaces/IERC721.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

import "@std/Test.sol";

contract AVAXTest is Test {
    using stdStorage for StdStorage;

    AVAX marketplace;
    MockERC721 token;
    MockERC721 tokenUnapproved;

    address public stargateRouter = 0x45A01E4e04F14f7A4a6702c74187c5F6222033cd;
    address public stargateBridge = 0x296F55F8Fb28E498B858d0BcDA06D955B2Cb3f97;
    address public dexRouter = 0x60aE616a2155Ee3d9A68541Ba4544862310933d4;
    address public usdc = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address public wavax = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

    address public constant owner = address(0x420);
    address public constant minter = address(0xBEEF);
    address public constant user = address(0x1337);
    address public constant mockCrosschainMarketplaceETH = address(0xCAFE);

    uint16 currentChainId = 6;
    uint16 interactingChainId = 1;

    function setUp() public {
        // console.log(unicode"🧪 Testing...");
        vm.prank(owner);
        marketplace = new AVAX(
            currentChainId,
            stargateRouter,
            dexRouter,
            usdc,
            wavax
        );

        token = new MockERC721();
        tokenUnapproved = new MockERC721();

        vm.prank(owner);
        marketplace.approveRouters();

        vm.label(wavax, "WAVAX");
        vm.label(usdc, "USDC");

        _mintSingle();
    }

    function testMetadata() public {
        assertEq(address(marketplace.stargateRouter()), stargateRouter);
        assertEq(address(marketplace.dexRouter()), dexRouter);
        assertEq(address(marketplace.USDC()), usdc);
        assertEq(address(marketplace.wrappedNative()), wavax);
    }

    function testSetCrosschainMarketplace() public {
        _setMarketplace(interactingChainId, mockCrosschainMarketplaceETH);
    }

    function testCannotSetCrosschainMarketplaceIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        marketplace.setMarketplace(
            interactingChainId,
            abi.encodePacked(mockCrosschainMarketplaceETH)
        );
    }

    function testAddNFT() public {
        _approveContract(address(token));
    }

    function testCannotAddNFTIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        marketplace.addNFTContract(address(token));
    }

    function testListApprovedNFT() public {
        _listItemLocally();
    }

    function testQuoteLayerZeroFee() public {
        console.log(_estimateMessageFees());
    }

    function testCannotListUnapprovedNFT() public {
        vm.prank(user);
        tokenUnapproved.mint();

        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplaceEventsAndErrors.NotApprovedNFT.selector
            )
        );
        vm.prank(user);
        marketplace.listItem(address(tokenUnapproved), 0, 1 ether, false);

        (, , , , uint256 price, AVAX.ListingStatus status) = marketplace
            .getSellerListings(
                keccak256(
                    abi.encodePacked(address(tokenUnapproved), uint256(0))
                )
            );

        assert(status == AVAX.ListingStatus.INACTIVE);
    }

    function testEditSalePrice() public {
        _approveContract(address(token));
        _listItemLocally();

        vm.prank(minter);
        marketplace.editPrice(address(token), 0, 2 ether);
        (, , , , uint256 price, AVAX.ListingStatus status) = marketplace
            .getSellerListings(
                keccak256(abi.encodePacked(address(token), uint256(0)))
            );
        assertEq(price, 2 ether);
        assert(status == AVAX.ListingStatus.ACTIVE_LOCAL);
    }

    function testCannotEditSalePriceIfNotTokenOwner() public {
        _approveContract(address(token));
        _listItemLocally();

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplaceEventsAndErrors.NotTokenOwner.selector
            )
        );
        marketplace.editPrice(address(token), 0, 2 ether);
        (, , , , uint256 price, AVAX.ListingStatus status) = marketplace
            .getSellerListings(
                keccak256(abi.encodePacked(address(token), uint256(0)))
            );
    }

    function testSetMarketplaceTxFee() public {
        vm.prank(owner);
        marketplace.setFee(250);

        assertEq(marketplace.fee(), uint256(250));
    }

    function testCannotSetFeeIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        marketplace.setFee(250);
    }

    function testCancelListing() public {
        _approveContract(address(token));
        _listItemLocally();
        _delistItem();
    }

    function testCannotCancelListingIfNotTokenOwner() public {
        _approveContract(address(token));
        _listItemLocally();

        startHoax(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplaceEventsAndErrors.NotTokenOwner.selector
            )
        );
        marketplace.delistItem(address(token), 0);

        (, , , , uint256 price, AVAX.ListingStatus status) = marketplace
            .getSellerListings(
                keccak256(abi.encodePacked(address(token), uint256(0)))
            );
        assert(status == AVAX.ListingStatus.ACTIVE_LOCAL);

        vm.stopPrank();
    }

    function testCannotPurchaseIfListingCancelled() public {
        _approveContract(address(token));
        _listItemLocally();
        _delistItem();

        startHoax(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplaceEventsAndErrors.NotActiveLocalListing.selector
            )
        );

        marketplace.buyLocal{value: 1 ether}(address(token), 0, user);

        vm.stopPrank();
    }

    function testCannotPurchaseIfLessFunds() public {
        _approveContract(address(token));
        _listItemLocally();

        startHoax(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplaceEventsAndErrors.InsufficientFunds.selector
            )
        );

        marketplace.buyLocal{value: 0.5 ether}(address(token), 0, user);

        vm.stopPrank();
    }

    function testCannotPurchaseIfMoreFunds() public {
        _approveContract(address(token));
        _listItemLocally();

        startHoax(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketplaceEventsAndErrors.ExcessFunds.selector
            )
        );

        marketplace.buyLocal{value: 1.5 ether}(address(token), 0, user);

        vm.stopPrank();
    }

    function testPurchaseListing() public {
        _approveContract(address(token));
        _listItemLocally();

        startHoax(user);

        marketplace.buyLocal{value: 1 ether}(address(token), 0, user);
        assertEq(token.ownerOf(0), user);

        vm.stopPrank();
    }

    function testPurchaseLocalListingWithCrosschainEnabled() public {
        _approveContract(address(token));
        _listItemCrosschain();

        startHoax(user);

        marketplace.buyLocal{value: 1 ether}(address(token), 0, user);
        assertEq(token.ownerOf(0), user);

        vm.stopPrank();
    }

    function testPurchaseListingAndExtractFee() public {
        _approveContract(address(token));
        _listItemLocally();

        vm.startPrank(user);
        vm.deal(user, 1 ether);

        marketplace.buyLocal{value: 1 ether}(address(token), 0, user);
        assertEq(token.ownerOf(0), user);

        vm.stopPrank();

        uint256 sellerFee = (marketplace.fee() * 1 ether) /
            marketplace.intConstant();
        uint256 price = 1 ether - sellerFee;

        assertEq(minter.balance, price);
    }

    function testCrosschainListingPurchaseChainA() public {
        _approveContract(address(token));
        _listItemCrosschain();

        uint256 fee = _estimateMessageFees();

        vm.prank(user);
        vm.deal(user, 1 ether + fee);
        marketplace.buyCrosschain{value: 1 ether + fee}(
            interactingChainId,
            address(token),
            0,
            user,
            1 ether
        );

        // TODO: add expectEmit
        // event SendMsg(uint8 msgType, uint64 nonce);
    }

    function testCrosschainListingPurchaseChainB() public {
        // 1 eth to usdc conversion
        uint256 amountStable = _imitateWrapAndSwapStable();

        _listItemCrosschain();

        console.log(IERC20Metadata(usdc).balanceOf(address(marketplace)));

        vm.startPrank(stargateRouter);

        (, , , , uint256 price, AVAX.ListingStatus status) = marketplace
            .getSellerListings(
                keccak256(abi.encodePacked(address(token), uint256(0)))
            );

        // calculate amount input based on precision of token
        // numTokens * (10**IERC20Metadata(usdc).decimals())
        marketplace.sgReceive(
            10006,
            abi.encodePacked(address(marketplace)),
            0,
            usdc,
            amountStable,
            abi.encode(address(token), 0, user)
        );
        assertEq(token.ownerOf(0), user);
        vm.stopPrank();

        // expect to receive approx 2% of 1 ether - 60 bps (+/- 0.05% because of DEX approximation)
        // ex. 59 bps (actual) vs 60 bps (expected) after swaps
        uint256 amountAfterFees = (((1 ether - ((1 ether * 60) / 10000)) *
            200) / 10000);
        uint256 amountLowBound = amountAfterFees -
            ((amountAfterFees * 50) / 10000);
        uint256 amountUpperBound = amountAfterFees +
            ((amountAfterFees * 50) / 10000);

        assertGt(
            IERC20Metadata(wavax).balanceOf(address(marketplace)),
            amountLowBound
        );
        assertLt(
            IERC20Metadata(wavax).balanceOf(address(marketplace)),
            amountUpperBound
        );
    }

    function _estimateMessageFees() internal returns (uint256) {
        IStargateRouter.lzTxObj memory lzTxParams = IStargateRouter.lzTxObj(
            500000,
            0,
            "0x"
        );

        return (
            marketplace.quoteLayerZeroFee(
                interactingChainId,
                abi.encode(address(token), 0, user),
                lzTxParams
            )
        );
    }

    /// @dev Imitates ETH -> WETH -> USDC (native)
    function _imitateWrapAndSwapStable() internal returns (uint256) {
        vm.startPrank(stargateRouter);
        vm.deal(stargateRouter, 1 ether);
        IWAVAX(wavax).deposit{value: 1 ether}();

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: wavax,
                tokenOut: usdc,
                fee: 3000,
                recipient: address(marketplace),
                deadline: block.timestamp,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        IERC20Metadata(wavax).approve(address(dexRouter), 2**256 - 1);
        uint256 amountOut = ISwapRouter(dexRouter).exactInputSingle(params);
        vm.stopPrank();

        return amountOut;
    }

    function _mintSingle() internal {
        vm.prank(minter);
        token.mint();

        assertEq(token.ownerOf(0), minter);
    }

    function _delistItem() internal {
        vm.prank(minter);
        marketplace.delistItem(address(token), 0);

        (, , , , uint256 price, AVAX.ListingStatus status) = marketplace
            .getSellerListings(
                keccak256(abi.encodePacked(address(token), uint256(0)))
            );
        assert(status == AVAX.ListingStatus.INACTIVE);
    }

    function _listItemCrosschain() internal {
        _approveContract(address(token));

        vm.prank(minter);
        marketplace.listItem(address(token), 0, 1 ether, true);
        (, , , , uint256 price, AVAX.ListingStatus status) = marketplace
            .getSellerListings(
                keccak256(abi.encodePacked(address(token), uint256(0)))
            );

        vm.prank(minter);
        token.setApprovalForAll(address(marketplace), true);

        assert(token.isApprovedForAll(minter, address(marketplace)));
        assertEq(price, 1 ether);
        assert(status == AVAX.ListingStatus.ACTIVE_CROSSCHAIN);
    }

    function _listItemLocally() internal {
        _approveContract(address(token));

        vm.prank(minter);
        marketplace.listItem(address(token), 0, 1 ether, false);
        (, , , , uint256 price, AVAX.ListingStatus status) = marketplace
            .getSellerListings(
                keccak256(abi.encodePacked(address(token), uint256(0)))
            );

        vm.prank(minter);
        token.setApprovalForAll(address(marketplace), true);

        assert(token.isApprovedForAll(minter, address(marketplace)));
        assertEq(price, 1 ether);
        assert(status == AVAX.ListingStatus.ACTIVE_LOCAL);
    }

    function _approveContract(address contractAddress) internal {
        vm.prank(owner);
        marketplace.addNFTContract(contractAddress);
        assert(marketplace.approvedNFTs(contractAddress));
    }

    function _setMarketplace(uint16 chainId, address crosschainMarketplace)
        internal
    {
        vm.prank(owner);
        marketplace.setMarketplace(
            chainId,
            abi.encodePacked(crosschainMarketplace)
        );
    }
}