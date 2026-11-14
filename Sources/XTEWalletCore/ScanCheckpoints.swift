// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.
//
// (height, block timestamp) pairs read from the live XTE chain on 2026-11-14
// (getblockheaderbyheight). Used to turn a wallet creation date into a scan
// height; the chain's real average block time differs from DIFFICULTY_TARGET,
// so a plain "seconds / target" estimate lands past the chain tip.

import Foundation

extension XTEConfig {
    public static let scanHeightCheckpoints: [(height: UInt64, timestamp: UInt64)] = [
        (1, 1692889600),
        (50001, 1695675330),
        (100001, 1697961762),
        (150001, 1700245043),
        (200001, 1702565718),
        (250001, 1704888081),
        (300001, 1707160594),
        (350001, 1709523703),
        (400001, 1711886161),
        (450001, 1714245221),
        (500001, 1716514630),
        (550001, 1718783128),
        (600001, 1721056247),
        (650001, 1723326852),
        (700001, 1725635429),
        (750001, 1727912650),
        (800001, 1730184444),
        (850001, 1732473677),
        (900001, 1734741847),
        (950001, 1737022307),
        (1000001, 1739319502),
        (1050001, 1741649822),
        (1100001, 1743956816),
        (1150001, 1746271037),
        (1200001, 1748600868),
        (1250001, 1750907528),
        (1300001, 1755467604),
        (1350001, 1759589997),
        (1400001, 1762069310),
        (1450001, 1764369661),
        (1500001, 1766682159),
        (1550001, 1768957124),
        (1600001, 1776585472),
        (1650001, 1779056282),
        (1700001, 1781328444),
        (1750001, 1786195533),
        (1800001, 1790783238),
        (1843571, 1794656605),
    ]
}
