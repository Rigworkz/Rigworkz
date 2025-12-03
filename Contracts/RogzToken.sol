// SPDX-License-Identifier: MIT

/**
* Official Website: https://rigworkz.xyz
* Telegram: https://t.me/rigworkz
* X: https://twitter.com/rigworkz
*/

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

interface IUniswapV2Router {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

error ZeroAddress();
error ExceedsTaxCap(uint256 bps);
error ExcludedAddProhibited();
error TransferAmountExceedsMaxTx(uint256 amount, uint256 maxTx);
error WalletExceedsMax(uint256 balance, uint256 maxWallet);
error InvalidAllocation();
error ContractAddressNotAllowed();
error InvalidMaxTxAmount();
error InvalidMaxWalletAmount();

contract RigWorkZ is ERC20, ERC20Permit, AccessControl {
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint16 public constant TAX_CAP_BPS = 500;
    uint16 public constant BPS_DENOM = 10000;

    bytes32 public constant TIMELOCK_ROLE = DEFAULT_ADMIN_ROLE;

    uint16 public buyTaxBps;
    uint16 public sellTaxBps;

    struct TaxBeneficiary {
        address wallet;
        uint16 percentage;
    }
    
    TaxBeneficiary public investmentWallet;
    TaxBeneficiary public marketingWallet;
    TaxBeneficiary public developmentWallet;
    TaxBeneficiary public treasuryWallet;

    uint256 public swapThreshold;
    IUniswapV2Router public immutable router;
    address public immutable WETH;

    mapping(address => bool) public pairs;
    mapping(address => bool) public excluded;

    bool public limitsDisabled;
    uint256 public maxTxAmount;
    uint256 public maxWalletAmount;

    bool private swapping;

    event TaxesUpdated(uint16 buyBps, uint16 sellBps);
    event SwapThresholdUpdated(uint256 threshold);
    event PairSet(address pair, bool isPair);
    event ExcludedSet(address account, bool isExcluded);
    event LimitsUpdated(uint256 maxTx, uint256 maxWallet);
    event LimitsDisabled();
    event TaxDistributed(address indexed wallet, uint256 ethAmount);
    event SwapFailed(uint256 tokenAmount);
    event TaxBeneficiariesUpdated();

    modifier lockTheSwap() {
        swapping = true;
        _;
        swapping = false;
    }

    modifier onlyTimelock() {
        require(hasRole(TIMELOCK_ROLE, msg.sender), "Not timelock");
        _;
    }

    constructor() ERC20("RigWorkZ Token", "ROGZ") ERC20Permit("RigWorkZ Token") {
        address _timelock = 0x2f6916264BCF19aB644C0909Ba6ed16ac06DCaDB;
        address _investmentWallet = 0xe5dE8Ed957c83e1B7CCE1f8A6Dd7028d8C54DA94;
        address _marketingWallet = 0xA22239000BbE1715fa144A61dE9eD19BFE0411B2;
        address _developmentWallet = 0x068D8314CaA4612f617b6dC997fca671360134e8;
        address _treasuryWallet = 0x58409F341E5B739d55C1e3343C12b96A63BD4fa8;
        address _router = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D; 
        address _weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

        _grantRole(TIMELOCK_ROLE, _timelock);

        investmentWallet = TaxBeneficiary(_investmentWallet, 50);
        marketingWallet = TaxBeneficiary(_marketingWallet, 25);
        developmentWallet = TaxBeneficiary(_developmentWallet, 15);
        treasuryWallet = TaxBeneficiary(_treasuryWallet, 10);

        router = IUniswapV2Router(_router);
        WETH = _weth;

        buyTaxBps = 500;
        sellTaxBps = 500;
        swapThreshold = (MAX_SUPPLY * 1) / 10000;

        maxTxAmount = MAX_SUPPLY / 100;
        maxWalletAmount = (MAX_SUPPLY * 2) / 100;

        excluded[address(this)] = true;
        excluded[_treasuryWallet] = true;
        excluded[_investmentWallet] = true;
        excluded[_marketingWallet] = true;
        excluded[_developmentWallet] = true;
        excluded[_timelock] = true;
        excluded[_router] = true;

        _mint(_timelock, MAX_SUPPLY);

        _approve(address(this), _router, type(uint256).max);
    }

    function updateTaxBeneficiaries(
        address _investment,
        uint16 _investmentPct,
        address _marketing,
        uint16 _marketingPct,
        address _development,
        uint16 _developmentPct,
        address _treasury,
        uint16 _treasuryPct
    ) external onlyTimelock {
        require(_investment != address(0), "Investment cannot be zero");
        require(_marketing != address(0), "Marketing cannot be zero");
        require(_development != address(0), "Development cannot be zero");
        require(_treasury != address(0), "Treasury cannot be zero");
        
        if (_investmentPct + _marketingPct + _developmentPct + _treasuryPct != 100) {
            revert InvalidAllocation();
        }

        investmentWallet = TaxBeneficiary(_investment, _investmentPct);
        marketingWallet = TaxBeneficiary(_marketing, _marketingPct);
        developmentWallet = TaxBeneficiary(_development, _developmentPct);
        treasuryWallet = TaxBeneficiary(_treasury, _treasuryPct);

        emit TaxBeneficiariesUpdated();
    }

    function setTaxes(uint16 _buyBps, uint16 _sellBps) external onlyTimelock {
        if (_buyBps > TAX_CAP_BPS || _sellBps > TAX_CAP_BPS) revert ExceedsTaxCap(TAX_CAP_BPS);
        buyTaxBps = _buyBps;
        sellTaxBps = _sellBps;
        emit TaxesUpdated(_buyBps, _sellBps);
    }

    function setSwapThreshold(uint256 _threshold) external onlyTimelock {
        uint256 min = (MAX_SUPPLY * 1) / 10000;
        uint256 max = (MAX_SUPPLY * 20) / 10000;
        require(_threshold >= min && _threshold <= max, "swapThreshold out of range");
        swapThreshold = _threshold;
        emit SwapThresholdUpdated(_threshold);
    }

    function setPair(address _pair, bool _isPair) external onlyTimelock {
        if (_pair == address(0)) revert ZeroAddress();
        pairs[_pair] = _isPair;
        emit PairSet(_pair, _isPair);
    }

    function setExcluded(address _who, bool _isExcluded) external onlyTimelock {
        if (_who == address(0)) revert ZeroAddress();
        excluded[_who] = _isExcluded;
        emit ExcludedSet(_who, _isExcluded);
    }

    function disableLimits() external onlyTimelock {
        limitsDisabled = true;
        emit LimitsDisabled();
    }

    function setMaxTx(uint256 _maxTx) external onlyTimelock {
        // Minimum 1% of MAX_SUPPLY - protects users from over-restriction
        uint256 minMaxTx = MAX_SUPPLY / 100;  // FIXED: 1% not 0.1%
        if (_maxTx < minMaxTx) revert InvalidMaxTxAmount();
        if (_maxTx > maxWalletAmount) revert InvalidMaxTxAmount();
        maxTxAmount = _maxTx;
        emit LimitsUpdated(maxTxAmount, maxWalletAmount);
    }

    function setMaxWallet(uint256 _maxWallet) external onlyTimelock {
        // Minimum 2% of MAX_SUPPLY - protects users from over-restriction
        uint256 minMaxWallet = (MAX_SUPPLY * 2) / 100;  // FIXED: 2% not 0.1%
        if (_maxWallet < minMaxWallet) revert InvalidMaxWalletAmount();
        if (_maxWallet < maxTxAmount) revert InvalidMaxWalletAmount();
        maxWalletAmount = _maxWallet;
        emit LimitsUpdated(maxTxAmount, maxWalletAmount);
    }

    function _update(address from, address to, uint256 amount) internal override {

        if (!limitsDisabled) {
            if (!excluded[from] && !excluded[to]) {
                if (amount > maxTxAmount) revert TransferAmountExceedsMaxTx(amount, maxTxAmount);

                if (!pairs[to] && to != address(0)) {
                    uint256 newBalance = balanceOf(to) + amount;
                    if (newBalance > maxWalletAmount) revert WalletExceedsMax(newBalance, maxWalletAmount);
                }
            }
        }

        uint256 feeAmount = 0;
        bool takeFee = true;
        bool isBuy = pairs[from];
        bool isSell = pairs[to];

        if (excluded[from] || excluded[to]) {
            takeFee = false;
        }

        if (takeFee && (isBuy || isSell)) {
            uint16 taxBps = isBuy ? buyTaxBps : sellTaxBps;
            feeAmount = (amount * taxBps) / BPS_DENOM;
            if (feeAmount > 0) {
                super._update(from, address(this), feeAmount);
            }
        }

        uint256 sendAmount = amount - feeAmount;
        super._update(from, to, sendAmount);

        if (isSell && !swapping && from != address(this)) {
            uint256 contractTokenBalance = balanceOf(address(this));
            if (contractTokenBalance >= swapThreshold) {
                _swapAndDistribute(swapThreshold);
            }
        }
    }

    function _swapAndDistribute(uint256 tokenAmount) internal lockTheSwap {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WETH;
        
        try
            router.swapExactTokensForETHSupportingFeeOnTransferTokens(
                tokenAmount,
                0,
                path,
                address(this),
                block.timestamp + 180
            )
        {
            uint256 ethBal = address(this).balance;
            if (ethBal > 0) {
                _distributeTaxes(ethBal);
            } else {
                emit SwapFailed(tokenAmount);
            }
        } catch {
            emit SwapFailed(tokenAmount);
        }
    }

    function _distributeTaxes(uint256 totalETH) internal {
        uint256 investmentAmount = (totalETH * investmentWallet.percentage) / 100;
        uint256 marketingAmount = (totalETH * marketingWallet.percentage) / 100;
        uint256 developmentAmount = (totalETH * developmentWallet.percentage) / 100;
        
        uint256 sentAmount = 0;

        if (investmentAmount > 0 && investmentWallet.wallet != address(0)) {
            (bool success, ) = payable(investmentWallet.wallet).call{value: investmentAmount}("");
            if (success) {
                emit TaxDistributed(investmentWallet.wallet, investmentAmount);
                sentAmount += investmentAmount;
            }
        }

        if (marketingAmount > 0 && marketingWallet.wallet != address(0)) {
            (bool success, ) = payable(marketingWallet.wallet).call{value: marketingAmount}("");
            if (success) {
                emit TaxDistributed(marketingWallet.wallet, marketingAmount);
                sentAmount += marketingAmount;
            }
        }

        if (developmentAmount > 0 && developmentWallet.wallet != address(0)) {
            (bool success, ) = payable(developmentWallet.wallet).call{value: developmentAmount}("");
            if (success) {
                emit TaxDistributed(developmentWallet.wallet, developmentAmount);
                sentAmount += developmentAmount;
            }
        }

        uint256 treasuryAmount = totalETH - sentAmount;
        if (treasuryAmount > 0 && treasuryWallet.wallet != address(0)) {
            (bool success, ) = payable(treasuryWallet.wallet).call{value: treasuryAmount}("");
            if (success) emit TaxDistributed(treasuryWallet.wallet, treasuryAmount);
        }
    }

    receive() external payable {}

    function isExcluded(address who) external view returns (bool) {
        return excluded[who];
    }

    function getTaxBeneficiaries() external view returns (
        address investment, uint16 investmentPct,
        address marketing, uint16 marketingPct,
        address development, uint16 developmentPct,
        address treasury, uint16 treasuryPct
    ) {
        return (
            investmentWallet.wallet, investmentWallet.percentage,
            marketingWallet.wallet, marketingWallet.percentage,
            developmentWallet.wallet, developmentWallet.percentage,
            treasuryWallet.wallet, treasuryWallet.percentage
        );
    }
}