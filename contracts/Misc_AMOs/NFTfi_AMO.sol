// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.4;

import "../FXS/IFxs.sol";
import "../Frax/IFrax.sol";
import "../Frax/IFraxAMOMinter.sol";
import "../ERC20/ERC20.sol";
import "../Staking/Owned.sol";
import "../Uniswap/TransferHelper.sol";
import "../Math/SafeMath.sol";

// I noticed you were not importing any pre-fab interfaces so I just defined this one for simplicity
interface IERC721 {
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;
}

interface INFTfi {
    function loanRepaidOrLiquidated(uint256) external returns (bool);
    function beginLoan(
        uint256 _loanPrincipalAmount,
        uint256 _maximumRepaymentAmount,
        uint256 _nftCollateralId,
        uint256 _loanDuration,
        uint256 _loanInterestRateForDurationInBasisPoints,
        uint256 _adminFeeInBasisPoints,
        uint256[2] memory _borrowerAndLenderNonces,
        address _nftCollateralContract,
        address _loanERC20Denomination,
        address _borrower,
        bytes[2] memory _borrowerLenderSignatures
    ) external returns (uint256);

    function liquidateOverdueLoan(uint256 _loanId) external;
}

contract NFTfiAMO is Owned {
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */
    IFrax private FRAX = IFrax(0x853d955aCEf822Db058eb8505911ED77F175b99e);
    IFxs private FXS = IFxs(0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0);
    IFraxAMOMinter private amo_minter;

    // NFTfi Loan Creator
    INFTfi private nftFi;

    address public timelock_address;
    address public custodian_address;

    uint256 private constant PRICE_PRECISION = 1e6;

    struct Loan {
        uint256 loanId;
        uint256 loanPrincipalAmount;
    }

    mapping(uint256 => bool) private liquidatedOrSettledLoans;
    mapping(uint256 => Loan) public loanIdToLoan;

    uint[] public loans;

    uint256 public totalFraxOutstanding;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _owner_address,
        address _amo_minter_address,
        address _nftFi_address
    ) Owned(_owner_address) {
        amo_minter = IFraxAMOMinter(_amo_minter_address);
        nftFi = INFTfi(_nftFi_address);

        // Get the custodian and timelock addresses from the minter
        custodian_address = amo_minter.custodian_address();
        timelock_address = amo_minter.timelock_address();
    }

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnGov() {
        require(msg.sender == timelock_address || msg.sender == owner, "Not owner or timelock");
        _;
    }

    modifier onlyByOwnGovCust() {
        require(
            msg.sender == timelock_address || msg.sender == owner || msg.sender == custodian_address,
            "Not owner, tlck, or custd"
        );
        _;
    }

    /* ========== VIEWS ========== */

    function showAllocations() public view returns (uint256[3] memory allocations) {
        // All numbers given are in FRAX unless otherwise stated
        allocations[0] = FRAX.balanceOf(address(this)); // Unallocated FRAX
        allocations[1] = totalFraxOutstanding; // FRAX oustanding

        uint256 sum_frax = allocations[0] + allocations[1];
        allocations[2] = sum_frax; // Total FRAX possessed in various forms
    }

    function dollarBalances() public view returns (uint256 frax_val_e18, uint256 collat_val_e18) {
        frax_val_e18 = showAllocations()[2];
        collat_val_e18 = (frax_val_e18).mul(FRAX.global_collateral_ratio()).div(PRICE_PRECISION);
    }

    // Backwards compatibility
    function mintedBalance() public view returns (int256) {
        return amo_minter.frax_mint_balances(address(this));
    }

    /* ========== NFTfi ========== */

    function lendFraxForNFT(
        uint256 _loanPrincipalAmount,
        uint256 _maximumRepaymentAmount,
        uint256 _nftCollateralId,
        uint256 _loanDuration,
        uint256 _loanInterestRateForDurationInBasisPoints,
        uint256 _adminFeeInBasisPoints,
        uint256[2] memory _borrowerAndLenderNonces,
        address _nftCollateralContract,
        address _loanERC20Denomination,
        address _borrower,
        bytes[2] memory _borrowerLenderSignatures
    ) public onlyByOwnGovCust {
        totalFraxOutstanding += _loanPrincipalAmount;

        FRAX.approve(address(nftFi), _loanPrincipalAmount);

        (uint256 _loanId) = nftFi.beginLoan(
            _loanPrincipalAmount,
            _maximumRepaymentAmount,
            _nftCollateralId,
            _loanDuration,
            _loanInterestRateForDurationInBasisPoints,
            _adminFeeInBasisPoints,
            _borrowerAndLenderNonces,
            _nftCollateralContract,
            _loanERC20Denomination,
            _borrower,
            _borrowerLenderSignatures
        );

        loanIdToLoan[_loanId] = Loan({
            loanId: _loanId,
            loanPrincipalAmount: _loanPrincipalAmount
        });

        loans.push(_loanId);
    }

    function liquidateLoan(uint256 _loanId, bool _listForAuction) public {
        // Could incentivize people to liquidate overdue loans
        totalFraxOutstanding -= loanIdToLoan[_loanId].loanPrincipalAmount;
        liquidatedOrSettledLoans[_loanId] = true;
        nftFi.liquidateOverdueLoan(_loanId);
        if (_listForAuction) {
            // List for auction here
        }
    }

    function updateAccountingForRepaidLoans(uint256 _loanId) public {
        require(nftFi.loanRepaidOrLiquidated(_loanId) == true, "Loan must be repaid before updating accounting");
        require(liquidatedOrSettledLoans[_loanId] == false, "Loan has already been liquidated");
        liquidatedOrSettledLoans[_loanId] = true; // Ensures this can only be called once per loan
        totalFraxOutstanding -= loanIdToLoan[_loanId].loanPrincipalAmount;
    }

    // Do to the poor design of NFTfi contracts, I pretend that they call this function whenever they repay a loan,
    // otherwise there is no way to make sure totalFraxOutstanding is accurate which in turn breaks showAllocations()
    function onLoanRepaid(uint256 _loanId) public {
        this.updateAccountingForRepaidLoans(_loanId);
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external pure returns (bytes4) {
        return bytes4(0xf0b9e5ba); // sig of function
    }

    /* ========== Burns and givebacks ========== */

    // Burn unneeded or excess FRAX. Goes through the minter
    function burnFRAX(uint256 frax_amount) public onlyByOwnGovCust {
        FRAX.approve(address(amo_minter), frax_amount);
        amo_minter.burnFraxFromAMO(frax_amount);
    }

    // Burn unneeded FXS. Goes through the minter
    function burnFXS(uint256 fxs_amount) public onlyByOwnGovCust {
        FXS.approve(address(amo_minter), fxs_amount);
        amo_minter.burnFxsFromAMO(fxs_amount);
    }

    /* ========== RESTRICTED GOVERNANCE FUNCTIONS ========== */

    function setAMOMinter(address _amo_minter_address) external onlyByOwnGov {
        amo_minter = IFraxAMOMinter(_amo_minter_address);

        // Get the custodian and timelock addresses from the minter
        custodian_address = amo_minter.custodian_address();
        timelock_address = amo_minter.timelock_address();

        // Make sure the new addresses are not address(0)
        require(custodian_address != address(0) && timelock_address != address(0), "Invalid custodian or timelock");
    }

    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyByOwnGov {
        TransferHelper.safeTransfer(address(tokenAddress), msg.sender, tokenAmount);
    }

    function transferERC721(
        address _contractId,
        address _from,
        address _to,
        uint256 _tokenId
    ) external onlyByOwnGov returns (bool, bytes memory) {
        IERC721(_contractId).safeTransferFrom(_from, _to, _tokenId);
    }

    // Generic proxy
    function execute(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) external onlyByOwnGov returns (bool, bytes memory) {
        (bool success, bytes memory result) = _to.call{ value: _value }(_data);
        return (success, result);
    }
}
