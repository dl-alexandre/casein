package com.example.casein_mob

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Casein brand dark background — matches CaseinMob.Theme / web base-300. */
val ColdStartBackground = Color(0xFF13171C)

/** Indigo primary — matches CaseinMob.Theme / web --color-primary. */
val ColdStartOnBackground = Color(0xFFE6EDF5)

val ColdStartMuted = Color(0xFF8A94A2)

val ColdStartError = Color(0xFFFF5470)

/**
 * Static native cold-start chrome. No spin/pulse/ping — reduced-motion is the
 * default motion scale; this is a static branded affordance only.
 */
@Composable
fun ColdStartSurface(
    phase: ColdStartPhase,
    showNarration: Boolean,
    modifier: Modifier = Modifier,
) {
    val description =
        when (phase) {
            ColdStartPhase.Starting -> stringResource(R.string.cold_start_starting_cd)
            ColdStartPhase.Failed -> stringResource(R.string.cold_start_failed_cd)
            ColdStartPhase.Ready -> ""
        }

    Box(
        modifier =
            modifier
                .fillMaxSize()
                .background(ColdStartBackground)
                .semantics {
                    testTag = "cold_start_surface"
                    if (description.isNotEmpty()) {
                        contentDescription = description
                    }
                },
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier.padding(32.dp),
        ) {
            Image(
                painter = painterResource(R.mipmap.ic_launcher),
                contentDescription = null,
                modifier = Modifier.size(72.dp),
            )
            Text(
                text = stringResource(R.string.app_name),
                color = ColdStartOnBackground,
                fontSize = 22.sp,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
            )
            when (phase) {
                ColdStartPhase.Starting -> {
                    if (showNarration) {
                        Text(
                            text = stringResource(R.string.cold_start_starting),
                            color = ColdStartMuted,
                            fontSize = 15.sp,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.semantics { testTag = "cold_start_narration" },
                        )
                    }
                }
                ColdStartPhase.Failed -> {
                    Text(
                        text = stringResource(R.string.cold_start_failed_title),
                        color = ColdStartError,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Medium,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.semantics { testTag = "cold_start_failed" },
                    )
                    Text(
                        text = stringResource(R.string.cold_start_failed_body),
                        color = ColdStartMuted,
                        fontSize = 14.sp,
                        textAlign = TextAlign.Center,
                    )
                }
                ColdStartPhase.Ready -> Unit
            }
        }
    }
}
